// 远程控制/连接器/配置安全回归（任务清单 D 组）：
// D1 MCP 路由 / D2 bind 回滚 / D3 persist 串行 / D4 restore 重载 /
// D5 备份脱敏 / D6 cron 相位 / D7 隧道排空 / D9-D16 手机桥与 MCP /
// D17 rune 截断 / D18 手机号脱敏 / D19 prompts 拒链 / D20 YAML 转义。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_config_yaml.dart';
import 'package:my_ide/ai/agent_profiles.dart';
import 'package:my_ide/ai/at_mentions.dart';
import 'package:my_ide/ai/cron_scheduler.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_api.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_auth.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_bridge_server.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_tunnel.dart';
import 'package:my_ide/ai/rules_hooks.dart';
import 'package:my_ide/ai/webhook_intake.dart';
import 'package:my_ide/diagnostics/app_logger.dart';
import 'package:my_ide/mcp/mcp_client.dart';
import 'package:my_ide/mcp/mcp_config.dart';
import 'package:my_ide/mcp/mcp_manager.dart';
import 'package:my_ide/prompts/prompt_templates.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:my_ide/settings/webdav_backup.dart';
import 'package:my_ide/skills/skill_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// lone surrogate（被拦腰切开的代理对）检测：emoji/扩展区字符截断乱码断言用。
bool hasLoneSurrogate(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 >= s.length) return true;
      final n = s.codeUnitAt(i + 1);
      if (n < 0xDC00 || n > 0xDFFF) return true;
      i++;
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

/// 最小 MCP 假进程：initialize/tools-list/tools/call 应答，[failInitialize]
/// 时 initialize 回 JSON-RPC error（连接快速失败进退避）。
class FakeMcpProc implements Process {
  FakeMcpProc({this.failInitialize = false});

  final bool failInitialize;
  final stdoutCtrl = StreamController<List<int>>();
  final stderrCtrl = StreamController<List<int>>();
  final _exitCode = Completer<int>();

  @override
  IOSink get stdin => _FakeStdin(this);

  @override
  Stream<List<int>> get stdout => stdoutCtrl.stream;
  @override
  Stream<List<int>> get stderr => stderrCtrl.stream;
  @override
  Future<int> get exitCode => _exitCode.future;
  @override
  int get pid => 424244;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    return true;
  }

  void reply(Map<String, dynamic> msg, Map<String, dynamic> payload) {
    stdoutCtrl.add(utf8.encode('${jsonEncode({
          'jsonrpc': '2.0',
          'id': msg['id'],
          ...payload,
        })}\n'));
  }

  void onRequest(String line) {
    Map<String, dynamic> msg;
    try {
      msg = Map<String, dynamic>.from(jsonDecode(line) as Map);
    } catch (_) {
      return;
    }
    if (!msg.containsKey('id')) return;
    if (failInitialize) {
      reply(msg, {
        'error': {'code': -32601, 'message': 'nope'},
      });
      return;
    }
    final method = '${msg['method']}';
    if (method == 'initialize') {
      reply(msg, {
        'result': {
          'protocolVersion': '2024-11-05',
          'capabilities': <String, dynamic>{},
          'serverInfo': {'name': 'fake', 'version': '0.0.1'},
        },
      });
    } else if (method == 'tools/list') {
      reply(msg, {
        'result': {
          'tools': [
            {
              'name': 'echo',
              'description': '回声',
              'inputSchema': {
                'type': 'object',
                'properties': <String, dynamic>{},
              },
            },
          ],
        },
      });
    } else if (method == 'tools/call') {
      reply(msg, {
        'result': {
          'content': [
            {'type': 'text', 'text': 'pong'},
          ],
        },
      });
    } else {
      reply(msg, {
        'result': <String, dynamic>{},
      });
    }
  }
}

class _FakeStdin implements IOSink {
  _FakeStdin(this._proc);
  final FakeMcpProc _proc;

  @override
  void writeln([Object? obj = '']) {
    final s = '$obj';
    if (s.isNotEmpty) _proc.onRequest(s);
  }

  @override
  Future<void> flush() => Future<void>.value();
  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding value) {}
  @override
  void write(Object? obj) => writeln(obj);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      writeln(objects.join(separator));
  @override
  void writeCharCode(int charCode) => writeln(String.fromCharCode(charCode));
  @override
  void add(List<int> data) => writeln(utf8.decode(data, allowMalformed: true));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Future<void>.value();
}

void main() {
  tearDown(() {
    McpSession.processFactoryForTest = null;
  });

  group('MCP 工具路由与持久化（D1/D3/D14）', () {
    late McpManager manager;

    Future<void> clearAll() async {
      for (final s in List<McpServerConfig>.from(manager.servers)) {
        await manager.remove(s.id);
      }
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();
      manager = McpManager.instance;
      await clearAll();
    });
    tearDown(clearAll);

    test('D1：含空格与中文的服务器名按 qualifiedName 正常路由调用', () async {
      final procs = <FakeMcpProc>[];
      McpSession.processFactoryForTest = (command, args) async {
        final proc = FakeMcpProc();
        procs.add(proc);
        return proc;
      };
      await manager.upsert(McpServerConfig(
        id: 'notion',
        name: 'Notion API',
        enabled: true,
        command: 'node',
      ));
      await manager.upsert(McpServerConfig(
        id: 'cn',
        name: '中文工具',
        enabled: true,
        command: 'node',
      ));
      await manager.connect('notion');
      await manager.connect('cn');
      // safeToken 前缀路由：空格折叠为下划线后仍能反查到原 server。
      final r1 = await manager
          .callQualifiedTool('mcp__Notion_API__echo', {})
          .timeout(const Duration(seconds: 10));
      expect(r1.ok, isTrue, reason: '含空格 server 名此前路由恒失败');
      expect(r1.output, contains('pong'));
      // 纯中文名：safeToken 全下划线，splitQualifiedName 回退解析 + 路由。
      final def = manager.allTools.firstWhere((t) => t.serverId == 'cn');
      expect(def.qualifiedName, startsWith('mcp__'));
      final split = McpToolDef.splitQualifiedName(def.qualifiedName);
      expect(split, isNotNull, reason: '纯中文名此前直接判"工具名格式错误"');
      final r2 = await manager
          .callQualifiedTool(def.qualifiedName, {})
          .timeout(const Duration(seconds: 10));
      expect(r2.ok, isTrue);
      // 反查 serverId 同口径。
      expect(manager.serverIdOfQualified('mcp__Notion_API__echo'), 'notion');
    });

    test('D1：safeToken 碰撞按原名精确消歧，歧义时拒绝并告警', () async {
      McpSession.processFactoryForTest =
          (command, args) async => FakeMcpProc();
      await manager.upsert(McpServerConfig(
        id: 'sp',
        name: 'a b',
        enabled: true,
        command: 'node',
      ));
      await manager.upsert(McpServerConfig(
        id: 'us',
        name: 'a_b',
        enabled: true,
        command: 'node',
      ));
      await manager.connect('sp');
      await manager.connect('us');
      expect(manager.safeTokenCollisions(), isNotEmpty);
      // 同前缀碰撞：原名精确命中 `a_b` → 路由到原生名 server，不模糊兜底。
      final r = await manager
          .callQualifiedTool('mcp__a_b__echo', {})
          .timeout(const Duration(seconds: 10));
      expect(r.ok, isTrue);
      expect(manager.serverIdOfQualified('mcp__a_b__echo'), 'us');
      // 同名双 server（不同 id）：safeToken 碰撞且原名无法消歧 → 拒绝。
      await manager.upsert(McpServerConfig(
        id: 'dup-1',
        name: 'c d',
        enabled: true,
        command: 'node',
      ));
      await manager.upsert(McpServerConfig(
        id: 'dup-2',
        name: 'c d',
        enabled: true,
        command: 'node',
      ));
      final dup = await manager.callQualifiedTool('mcp__c_d__echo', {});
      expect(dup.ok, isFalse);
      expect(dup.output, contains('未找到 MCP 服务器'));
      expect(manager.serverIdOfQualified('mcp__c_d__echo'), isNull);
    });

    test('D3：并发持久化后盘上 snapshot 与数据一致（不误判恢复注入）', () async {
      McpSession.processFactoryForTest =
          (command, args) async => FakeMcpProc();
      await manager.upsert(McpServerConfig(
        id: 'p-a',
        name: 'p-a',
        enabled: false,
        command: 'node',
      ));
      await manager.upsert(McpServerConfig(
        id: 'p-b',
        name: 'p-b',
        enabled: false,
        command: 'node',
      ));
      // 两个 _persist 并发交错（此前三次 setString 交错可落盘 snapshot≠raw）。
      await Future.wait([
        manager.setToolEnabled('p-a', 'echo', enabled: false),
        manager.setToolEnabled('p-b', 'echo', enabled: false),
        manager.upsert(McpServerConfig(
          id: 'p-c',
          name: 'p-c',
          enabled: false,
          command: 'node',
        )),
      ]);
      // 等单飞队列排空。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('mcpServers');
      final snapshot = prefs.getString('mcpServersSnapshot');
      expect(raw, isNotNull);
      expect(snapshot, isNot('__writing__'));
      expect(snapshot, raw,
          reason: '并发 _persist 交错曾把 snapshot≠raw 落盘，下次启动全部 server 被误禁用');
      // 重放加载口径：数据与快照一致 → 不进"恢复注入"禁用分支。
      final decoded = jsonDecode(raw!) as List;
      expect(decoded.length, 3);
    });

    test('D14：退避中 remove 不删连接代际，重装后旧 inner 不复活建连', () async {
      final spawned = <FakeMcpProc>[];
      McpSession.processFactoryForTest = (command, args) async {
        final proc = FakeMcpProc();
        spawned.add(proc);
        return proc;
      };
      await manager.upsert(McpServerConfig(
        id: 'd14',
        name: 'd14',
        enabled: true,
        command: 'node',
      ));
      await manager.connect('d14');
      final genBefore = manager.connectGenForTest('d14');
      expect(genBefore, isNotNull);
      // remove：代际保留递增（不删键）。
      await manager.remove('d14');
      final genAfterRemove = manager.connectGenForTest('d14');
      expect(genAfterRemove, isNotNull,
          reason: 'remove 删键后重装代际从 1 起算，与退避中旧 inner 的世代相等即复活并发建连');
      expect(genAfterRemove!, greaterThan(genBefore!));
      // 重装并连接：代际继续递增，旧 inner 世代必然失配。
      await manager.upsert(McpServerConfig(
        id: 'd14',
        name: 'd14',
        enabled: true,
        command: 'node',
      ));
      await manager.connect('d14');
      expect(manager.connectGenForTest('d14')!, greaterThan(genAfterRemove));
      // 只有一个 connected session（僵尸 inner 不产生第二次建连）。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(manager.statusOf('d14'), 'connected');
      expect(manager.sessionOf('d14'), isNotNull);
      expect(manager.sessionOf('d14')!.connected, isTrue);
      expect(spawned.length, 2, reason: '重装后只应新起一个进程（旧 inner 不复活建连）');
    });
  });

  group('MCP 日志脱敏与 rune 截断（D9/D17）', () {
    test('D9：refresh_token 等引号形态键打码（与 app_logger quotedKeys 同清单）', () {
      final out = McpSession.redactSecrets('{"refresh_token":"rt-123456"}');
      expect(out, contains('"refresh_token":"***"'));
      expect(out, isNot(contains('rt-123456')));
      // app_logger quotedKeys 清单里、mcp_client 此前缺失的键逐个验证。
      for (final key in [
        'secret_key',
        'app_secret',
        'access_key',
        'private_key',
        'signing_secret',
        'id_secret',
      ]) {
        final s = '{"$key":"value-123456"}';
        expect(McpSession.redactSecrets(s), isNot(contains('value-123456')),
            reason: '$key 应与 app_logger quotedKeys 同源覆盖');
        expect(AppLogger.redactSensitiveText(s),
            isNot(contains('value-123456')));
      }
      // 原有键不回归。
      expect(McpSession.redactSecrets('{"api_key":"sk12345678"}'),
          isNot(contains('sk12345678')));
    });

    test('D17：MCP 日志 1000 截断不切代理对', () async {
      final proc = FakeMcpProc();
      McpSession.processFactoryForTest = (command, args) async => proc;
      final session = McpSession(
        McpServerConfig(id: 'clip', name: 'clip', command: 'node'),
      );
      addTearDown(session.disconnect);
      await session.connect().timeout(const Duration(seconds: 10));
      final emoji = List.filled(600, '😀').join(); // 600 runes / 1200 units
      proc.stdoutCtrl.add(utf8.encode('${jsonEncode({
            'jsonrpc': '2.0',
            'method': 'notifications/message',
            'params': {'data': emoji},
          })}\n'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(session.logs, isNotEmpty);
      expect(session.logs.join().runes.length, greaterThanOrEqualTo(600));
      for (final l in session.logs) {
        expect(hasLoneSurrogate(l), isFalse,
            reason: '按 UTF-16 码元截到 1000 会劈裂 emoji 成乱码');
      }
    });
  });

  group('备份恢复与脱敏（D4/D5）', () {
    test('D4：恢复直写 mcpServers 后 McpManager 重载，旧内存表不回灌', () async {
      McpSession.processFactoryForTest =
          (command, args) async => FakeMcpProc();
      SharedPreferences.setMockInitialValues({
        'mcpServers': jsonEncode([
          {
            'id': 'srv-a',
            'name': 'srv-a',
            'enabled': false,
            'transport': 'stdio',
            'command': 'node',
          }
        ]),
        'mcpServersSnapshot': jsonEncode([
          {
            'id': 'srv-a',
            'name': 'srv-a',
            'enabled': false,
            'transport': 'stdio',
            'command': 'node',
          }
        ]),
      });
      await SettingsStore.init();
      final manager = McpManager.instance;
      await manager.ensureLoaded();
      expect(manager.servers.single.id, 'srv-a');
      // 模拟 webdav restore 直写 store（不经 manager）：换成 server B。
      final restored = jsonEncode([
        {
          'id': 'srv-b',
          'name': 'srv-b',
          'enabled': true,
          'transport': 'stdio',
          'command': 'node',
        }
      ]);
      await SettingsStore.instance.setString('mcpServers', restored);
      await manager.reloadFromStore();
      // 内存表已是恢复内容（恢复注入按门禁禁用）。
      expect(manager.servers.single.id, 'srv-b');
      // 用户启用 B 触发 _persist：盘上仍是恢复内容，不是旧表回灌。
      await manager.setEnabled('srv-b', true);
      final prefs = await SharedPreferences.getInstance();
      final disk = prefs.getString('mcpServers')!;
      expect(disk, contains('srv-b'));
      expect(disk, isNot(contains('srv-a')),
          reason: '恢复后旧内存表经 _persist 回灌会覆盖刚恢复的数据');
    });

    test('D5：备份 mcpServers 段 url/args 脱敏，恢复侧同序回填本地原值', () async {
      final redactedEntry = WebDavBackup.redactMcpServerEntryForTest({
        'id': 'srv',
        'name': 'srv',
        'enabled': false,
        'transport': 'stdio',
        'command': 'npx',
        'args': ['-y', 'pkg@1.0.0', '--api-key=sk-live-9999'],
        'url': 'https://mcp.example/sse?token=secret-tok-1&q=1',
      });
      expect(jsonEncode(redactedEntry), isNot(contains('sk-live-9999')));
      expect(jsonEncode(redactedEntry), isNot(contains('secret-tok-1')));
      expect(redactedEntry['args'][2], WebDavBackup.redacted);
      expect(redactedEntry['args'][1], 'pkg@1.0.0');
      expect(redactedEntry['url'], contains('q=1'));
      // 恢复侧：打码 args 按同序回填本地原值。
      SharedPreferences.setMockInitialValues({
        'mcpServers': jsonEncode([
          {
            'id': 'srv',
            'name': 'srv',
            'enabled': false,
            'transport': 'stdio',
            'command': 'npx',
            'args': ['-y', 'pkg@1.0.0', '--api-key=sk-local-8888'],
          }
        ]),
      });
      await SettingsStore.init();
      final store = SettingsStore.instance;
      final ok = await WebDavBackup.restore(store, {
        'version': WebDavBackup.backupVersion,
        'mcpServers': [redactedEntry],
      });
      expect(ok, isTrue);
      final disk =
          (jsonDecode(store.getString('mcpServers')!) as List).single as Map;
      expect(disk['args'], ['-y', 'pkg@1.0.0', '--api-key=sk-local-8888'],
          reason: '打码项须按同序回填本地原值（与 env 同口径）');
    });
  });

  group('手机桥 HTTP 语义（D2/D10/D11/D12/D15）', () {
    test('D2：start bind 失败后状态回滚，可再次 start', () async {
      final blocker = MobileBridge(
        read: _StubRead(),
        write: _StubWrite(),
      );
      final occupied = await blocker.start(0);
      addTearDown(blocker.stop);
      final victim = MobileBridge(
        read: _StubRead(),
        write: _StubWrite(),
      );
      // 端口被占：bind 抛错。
      await expectLater(
        victim.start(occupied.port),
        throwsA(anything),
      );
      // 状态已回滚：换个端口能重新 bind（此前 _closed 滞留 false，
      // 再次 start 命中"已运行"分支对 _server 解空崩溃）。
      final retried = await victim.start(0);
      expect(retried.port, greaterThan(0));
      await victim.stop();
    });

    test('D10：写出口业务失败映射业务码而非 405', () async {
      final bridge = MobileBridge(
        read: _StubRead(),
        write: _FailingWrite(
          onSend: () => throw MobileApiException(404, '会话不存在：ghost'),
        ),
      );
      final started = await bridge.start(0);
      addTearDown(bridge.stop);
      final code = bridge.pairingCode!.code;
      final token = bridge.auth.exchange(code)!.value;
      final res = await _httpJson(
        'POST',
        'http://127.0.0.1:${started.port}/api/send',
        body: {'sessionId': 'ghost', 'text': 'hi', 'messageId': 'm-1'},
        token: token,
      );
      expect(res['status'], 404, reason: '业务失败不再是 405');
      expect(res['body'], contains('会话不存在'));
      // 方法校验仍映射 405：GET 打 POST 端点。
      final wrong = await _httpJson(
        'GET',
        'http://127.0.0.1:${started.port}/api/send',
        token: token,
      );
      expect(wrong['status'], 405);
    });

    test('D11：过期会话 token 在鉴权/签发时清理，activeSessionCount 归零', () {
      var now = DateTime(2026, 1, 1);
      final auth = MobileBridgeAuth(
        sessionTtl: const Duration(milliseconds: 1),
        now: () => now,
      );
      auth.issueSession();
      auth.issueSession();
      expect(auth.activeSessionCount, 2);
      now = now.add(const Duration(milliseconds: 5));
      // resolve 触发清理。
      final r = auth.resolve('Bearer ${'a' * 64}');
      expect(r.token, isNull);
      expect(auth.activeSessionCount, 0, reason: '过期 token 永驻即无界增长+计数失真');
    });

    test('D12：Bearer 常量时间比较（等长异或累计语义）', () {
      expect(WebhookIntake.constantTimeEquals('abc', 'abc'), isTrue);
      expect(WebhookIntake.constantTimeEquals('abc', 'abd'), isFalse);
      expect(WebhookIntake.constantTimeEquals('abc', 'ab'), isFalse);
      // 鉴权链路复用同一实现：正确/错误 token。
      final auth = MobileBridgeAuth();
      final token = auth.issueSession();
      expect(auth.resolve('Bearer ${token.value}').token, isNotNull);
      expect(auth.resolve('Bearer ${'f' * 64}').token, isNull);
    });

    test('D15：messageId 防重放登记在校验后，400 重试不再误判 409', () async {
      final api = MobileBridgeApi(read: _StubRead(), write: _StubWrite());
      // 第一次：缺 text → 400（此前同 id 已被登记）。
      final bad = await api.handle('POST', '/api/send', {}, {
        'messageId': 'u-9',
        'sessionId': 's1',
      }, _tok());
      expect(bad.status, 400);
      // 第二次：补全参数的同 id 合法重试 → 202（旧实现误判 409）。
      final good = await api.handle('POST', '/api/send', {}, {
        'messageId': 'u-9',
        'sessionId': 's1',
        'text': 'hello',
      }, _tok());
      expect(good.status, 202);
      // 第三次：同 id 重放仍被拦截。
      final replay = await api.handle('POST', '/api/send', {}, {
        'messageId': 'u-9',
        'sessionId': 's1',
        'text': 'hello',
      }, _tok());
      expect(replay.status, 409);
    });
  });

  group('手机桥 WS 扇出与鉴权（D16）', () {
    test('D16：WS 鉴权凭据选择——Authorization 优先，query token 仅回环接受', () {
      expect(
        MobileBridge.wsAuthCredentialForTest(
          authHeader: 'Bearer h1',
          queryToken: 'q1',
          loopback: true,
        ),
        'Bearer h1',
      );
      expect(
        MobileBridge.wsAuthCredentialForTest(
          queryToken: 'q1',
          loopback: true,
        ),
        'Bearer q1',
      );
      expect(
        MobileBridge.wsAuthCredentialForTest(
          queryToken: 'q1',
          loopback: false,
        ),
        isNull,
        reason: '非回连直连的 query token 会进隧道日志（红线 4.7）',
      );
    });

    test('D16：两客户端分别订阅 A/B，事件按订阅集合过滤', () async {
      final bridge = MobileBridge(read: _StubRead(), write: _StubWrite());
      final started = await bridge.start(0);
      addTearDown(bridge.stop);
      final code = bridge.pairingCode!.code;
      final token = bridge.auth.exchange(code)!.value;

      Future<(WebSocket, List<String>)> connectAndSubscribe(
          List<String> sessions) async {
        final ws = await WebSocket.connect(
          'ws://127.0.0.1:${started.port}/ws',
          headers: {'authorization': 'Bearer $token'},
        );
        final got = <String>[];
        ws.listen((d) {
          final text = d is String ? d : utf8.decode(d as List<int>);
          final decoded = jsonDecode(text) as Map;
          if (decoded['type'] == 'pong') return;
          got.add('${decoded['sessionId']}');
        });
        ws.add(jsonEncode({'type': 'subscribe', 'sessions': sessions}));
        return (ws, got);
      }

      final (wsA, gotA) = await connectAndSubscribe(['sess-a']);
      final (wsB, gotB) = await connectAndSubscribe(['sess-b']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      bridge.events.emitStatus('sess-a', 'running');
      bridge.events.emitStatus('sess-b', 'finished');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(gotA, ['sess-a'], reason: '订阅 A 的客户端不得收到 B 的事件');
      expect(gotB, ['sess-b'], reason: '订阅 B 的客户端不得收到 A 的事件');
      await wsA.close();
      await wsB.close();
    });

    test('D16：回环直连 query token 可升级，隧道场景（非回环）被拒', () async {
      final bridge = MobileBridge(read: _StubRead(), write: _StubWrite());
      final started = await bridge.start(0);
      addTearDown(bridge.stop);
      final code = bridge.pairingCode!.code;
      final token = bridge.auth.exchange(code)!.value;
      // 回环直连：query token 兼容保留。
      final ws = await WebSocket.connect(
        'ws://127.0.0.1:${started.port}/ws?token=$token',
      );
      await ws.close();
      // 无任何凭据：401（HTTP 明文探测，升级前即被拒）。
      final res = await _httpJson('GET', 'http://127.0.0.1:${started.port}/ws');
      expect(res['status'], 401);
    });
  });

  group('隧道进程日志排空（D7）', () {
    test('D7：tailscale 拿到 URL 后 stdout/stderr 订阅常驻排空不退订', () async {
      final tmp = await Directory.systemTemp.createTemp('tunnel-d7-');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      await Directory('${tmp.path}/bin').create(recursive: true);
      // Windows 上规格 binName 为 tailscale.exe（发现按规格名找）。
      final bin = File(
        '${tmp.path}/bin/${Platform.isWindows ? 'tailscale.exe' : 'tailscale'}',
      );
      await bin.writeAsString('#!/bin/sh\n');
      final stdoutCtrl = StreamController<List<int>>();
      final stderrCtrl = StreamController<List<int>>();
      // tailscale funnel URL 由 stdout 直出：预灌一条（StreamController
      // 会缓冲到订阅建立后送达）。
      stdoutCtrl.add(utf8.encode('https://my-host.tail.ts.net funnel started\n'));
      final tunnel = MobileTunnel(
        workDir: tmp.path,
        searchBinDirs: ['${tmp.path}/bin'],
        processStarter: (exe, args, {mode = ProcessStartMode.normal}) async =>
            _FakeTunnelProcess(stdoutCtrl, stderrCtrl),
      );
      final handle = await tunnel.startTunnel(
        localPort: 59999,
        order: () => [MobileTunnelKind.tailscale],
      );
      expect(handle, isNotNull);
      expect(handle!.publicUrl, contains('ts.net'));
      // 订阅常驻：stdout 排空订阅仍挂着，持续写 256KB 不阻塞、不退订。
      expect(stdoutCtrl.hasListener, isTrue, reason: 'URL 抓到后退订会让 64KB 管道写满、隧道静默死亡');
      expect(stderrCtrl.hasListener, isTrue, reason: '未订阅的一路同样会写满管道');
      final big = List.filled(8192, 'x').join();
      for (var i = 0; i < 32; i++) {
        stdoutCtrl.add(utf8.encode(big));
        stderrCtrl.add(utf8.encode(big));
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(stdoutCtrl.hasListener, isTrue);
      expect(stderrCtrl.hasListener, isTrue);
      await stdoutCtrl.close();
      await stderrCtrl.close();
      await handle.stop();
    });
  });

  group('cron 调度相位与槽位（D6/D13/D17）', () {
    test('D6：宽限补跑直发路径 lastFire 记计划槽位而非实际时刻', () async {
      final sched = CronScheduler(onFire: (_) async {});
      final job = CronJob(
        id: 'grace',
        prompt: 'p',
        intervalMin: 10,
        lastFire: DateTime.now().subtract(const Duration(minutes: 15)),
      );
      sched.addOrUpdate(job);
      // 迟到 5min < 周期 10min：宽限补跑，计划槽位 = lastFire+interval。
      final slot = sched.scheduledSlotForTest('grace');
      expect(slot, isNotNull);
      await sched.debugFireScheduled('grace');
      // 直发分支此前记 now（≈实际触发时刻），运行耗时持续推挤相位。
      expect(job.lastFire, slot,
          reason: 'lastFire 应等于原计划槽位（lastFire+interval），不是实际触发时刻');
      expect(
        job.lastFire!.isBefore(DateTime.now().subtract(const Duration(minutes: 4))),
        isTrue,
        reason: '槽位在约 5 分钟前，而实际触发在当前时刻——两者被此前实现混为一谈',
      );
      sched.dispose();
    });

    test('D13：stopAll 清空计划槽位，load 删除的 job 槽位不残留', () {
      final sched = CronScheduler(onFire: (_) async {});
      sched.load([
        CronJob(id: 'ja', prompt: 'p', intervalMin: 5),
        CronJob(id: 'jb', prompt: 'p', intervalMin: 5),
      ]);
      expect(sched.scheduledSlotForTest('ja'), isNotNull);
      expect(sched.scheduledSlotForTest('jb'), isNotNull);
      // load 只含 C：A/B 的槽位不得残留。
      sched.load([CronJob(id: 'jc', prompt: 'p', intervalMin: 5)]);
      expect(sched.scheduledSlotForTest('ja'), isNull);
      expect(sched.scheduledSlotForTest('jb'), isNull);
      expect(sched.scheduledSlotForTest('jc'), isNotNull);
      sched.dispose();
    });

    test('D17：sessionId 超长钳制按 rune 截断不切代理对', () {
      final sid = List.filled(40, '😀').join();
      final job = CronJob.fromJson({
        'id': 'j',
        'prompt': 'p',
        'intervalMin': 5,
        'sessionId': sid,
      });
      expect(job, isNotNull);
      expect(hasLoneSurrogate(job!.sessionId), isFalse);
    });
  });

  group('日志与提示注入安全（D18/D19）', () {
    test('D18：紧邻标点分隔的第二个手机号同样脱敏', () {
      final out =
          AppLogger.redactSensitiveText('联系 13800138000,13900139000 收尾');
      expect('<redacted-phone>'.allMatches(out).length, 2,
          reason: '消费型右边界把分隔符吞掉后第二个号码漏脱敏');
      expect(out, isNot(contains('13900139000')));
      // 单号码语义不回归：边界字符保留。
      final single = AppLogger.redactSensitiveText('call 13800138000 now');
      expect(single, 'call <redacted-phone> now');
    });

    test('D19：项目 prompts 目录为符号链接时拒绝加载', () async {
      final root = await Directory.systemTemp.createTemp('prompts-d19-');
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });
      final outside = await Directory.systemTemp.createTemp('prompts-out-');
      addTearDown(() async {
        try {
          await outside.delete(recursive: true);
        } catch (_) {}
      });
      await File('${outside.path}/evil.md')
          .writeAsString('---\nname: evil\n---\n注入内容');
      final link = Link('${root.path}/.my_ide/prompts');
      await link.parent.create(recursive: true);
      await link.create(outside.path);
      final warnings = <String>[];
      final loaded = await PromptTemplateStore.loadProject(
        root.path,
        warnings: warnings,
      );
      expect(loaded, isEmpty, reason: '链接目录会把区外文件整批注入 prompt');
      expect(warnings, isNotEmpty);
      // 正常目录不回归。
      final normal = '${root.path}/real';
      await Directory('$normal/.my_ide/prompts')
          .create(recursive: true);
      await File('$normal/.my_ide/prompts/ok.md')
          .writeAsString('---\nname: ok\n---\n正文');
      final ok = await PromptTemplateStore.loadProject(normal);
      expect(ok, hasLength(1));
    });
  });

  group('配置导入导出（D20）', () {
    test('D20：modelId 含冒号引号时导出再导入往返相等', () {
      const tricky = 'gpt-4: preview "x" #tag';
      final bindings = <String, AgentProfileBinding>{
        'code': const AgentProfileBinding(
          providerId: 'p: 1',
          modelId: tricky,
          fallback: 'p: 1/m',
        ),
      };
      final yaml = AgentConfigYaml.exportBindings(bindings);
      final back = AgentConfigYaml.importBindings(yaml);
      expect(back, isNotNull);
      expect(back!['code']!.modelId, tricky);
      expect(back['code']!.providerId, 'p: 1');
      expect(back['code']!.fallback, 'p: 1/m');
    });
  });

  group('rune 截断收敛（D17：rules/mentions/skills/settings）', () {
    test('D17：规则 8K 截断、@diff 截断、skill 目录/正文截断、lint 命令钳制均不切代理对',
        () async {
      // 9000 runes（18000 UTF-16 units）：按 rune 截 8000 与按码元截 8000
      // 结果不同——按码元会在第 4000 个 emoji 中间劈出 lone surrogate。
      final emojiLong = List.filled(9000, '😀').join();
      // rules_hooks：AGENTS.md 超 8000 rune 截断。
      final root = await Directory.systemTemp.createTemp('rules-d17-');
      addTearDown(() async {
        try {
          await root.delete(recursive: true);
        } catch (_) {}
      });
      await File('${root.path}/AGENTS.md').writeAsString(emojiLong);
      final rules = await loadRules(root.path);
      expect(hasLoneSurrogate(rules), isFalse, reason: 'substring 拦腰切 emoji 出乱码');
      expect(rules.runes.length, lessThanOrEqualTo(8100));
      // at_mentions：@diff 8000 截断。
      final diffOut = await resolveAtMentions(
        '@diff',
        readDiff: () => emojiLong,
      );
      expect(hasLoneSurrogate(diffOut), isFalse);
      // skill 目录摘要（80 rune）与正文（8000 rune）截断。
      SharedPreferences.setMockInitialValues({});
      await SettingsStore.init();
      final skillRoot = await Directory.systemTemp.createTemp('skills-d17-');
      addTearDown(() async {
        try {
          await skillRoot.delete(recursive: true);
        } catch (_) {}
      });
      final desc = List.filled(100, '😀').join();
      final mgr = SkillManager.instance;
      // 注册扫描源（与既有 mcp 导入测试同口径），否则 refresh 找不到。
      await mgr.addExtraGlobalDir(skillRoot.path);
      final imported = await mgr.importSkillFromMcpText(
        serverName: 'srv',
        skillUri: 'skill://emoji/SKILL.md',
        skillMdText: '---\nname: emoji-skill\ndescription: $desc\n---\n\n$emojiLong',
        targetRoot: skillRoot.path,
      );
      expect(imported.name, 'emoji-skill');
      final catalog = mgr.buildSkillsCatalogPrompt();
      expect(hasLoneSurrogate(catalog), isFalse);
      final loaded = await mgr.loadSkillResult('emoji-skill');
      expect(loaded.ok, isTrue);
      expect(hasLoneSurrogate(loaded.body), isFalse,
          reason: '正文 8000 预算截断按 rune 收敛');
      // settings_store：lint/test 命令 400 rune 钳制。
      final longCmd = List.filled(500, '😀').join();
      await SettingsStore.instance.setAgentLintCommand(longCmd);
      await SettingsStore.instance.setAgentTestCommand(longCmd);
      final lint = SettingsStore.instance.agentLintCommand;
      final test = SettingsStore.instance.agentTestCommand;
      expect(hasLoneSurrogate(lint), isFalse);
      expect(hasLoneSurrogate(test), isFalse);
      expect(lint.runes.length, 400);
      expect(test.runes.length, 400);
    });
  });
}

/// 便捷：HTTP JSON 请求（D10/D16 集成用）。
Future<Map<String, dynamic>> _httpJson(
  String method,
  String url, {
  Object? body,
  String? token,
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse(url));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    return {'status': resp.statusCode, 'body': text};
  } finally {
    client.close(force: true);
  }
}

MobileSessionToken _tok() => MobileBridgeAuth().issueSession();

/// 只读桩。
class _StubRead implements MobileReadSource {
  @override
  Future<Map<String, dynamic>> bootstrap(String sessionToken) async =>
      {'projects': []};

  @override
  Future<Map<String, dynamic>?> session(String id) async => null;

  @override
  Future<Map<String, dynamic>> models() async => {'models': []};
}

/// 可编程写出口桩。
class _StubWrite implements MobileWriteSink {
  @override
  Future<void> send(
    String sessionId,
    String text, {
    List<Map<String, dynamic>> attachments = const [],
  }) async {}

  @override
  Future<String> newChat(String projectRoot, {String? model, String? text}) =>
      Future.value('s-new');

  @override
  Future<void> resolveApproval(String approvalId, bool approve) async {}

  @override
  Future<void> stop(String sessionId) async {}
}

/// D10：业务失败写出口。
class _FailingWrite implements MobileWriteSink {
  _FailingWrite({required this.onSend});

  final void Function() onSend;

  @override
  Future<void> send(
    String sessionId,
    String text, {
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    onSend();
  }

  @override
  Future<String> newChat(String projectRoot, {String? model, String? text}) =>
      Future.value('s-new');

  @override
  Future<void> resolveApproval(String approvalId, bool approve) async {}

  @override
  Future<void> stop(String sessionId) async {}
}

/// D7：stdio 全接通的假隧道进程。
class _FakeTunnelProcess implements Process {
  _FakeTunnelProcess(this._stdout, this._stderr);

  final StreamController<List<int>> _stdout;
  final StreamController<List<int>> _stderr;
  final _exit = Completer<int>();

  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 424245;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
