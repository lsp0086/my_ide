import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart'
    show AgentMode, ApprovalAction;
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/mcp/mcp_client.dart';
import 'package:my_ide/mcp/mcp_manager.dart';
import 'package:my_ide/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AiProviderConfig provider() => AiProviderConfig(
    id: 't',
    name: 't',
    baseUrl: 'http://127.0.0.1',
    fullUrl: true,
  );

  group('MCP 门禁修复回归', () {
    test('a) approveReadOutside=deny：敏感路径读取一律拒绝不弹窗', () async {
      final gate = ApprovalGate();
      final model = AiModelOption(id: 'm');
      final root = await Directory.systemTemp.createTemp('deny-read-');
      final reg = ToolRegistry(gate: gate)
        ..approveReadOutside = ApprovalAction.deny;
      try {
        await File('${root.path}/.env').writeAsString('SECRET=1\n');
        final r = await reg.executeWithGuards(
          toolName: 'read_file',
          args: {'path': '.env'},
          mode: AgentMode.agent,
          provider: provider(),
          model: model,
          rootPath: root.path,
          sessionId: 's',
        );
        expect(r?.ok, isFalse);
        // deny 档不再被 readZone==sensitive 分支降级为 ask。
        expect(r?.output, contains('读取已被审批策略拒绝'));
        // 直接拒绝：不落待审批弹窗。
        expect(gate.pendingApproval, isNull);
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('b) 无工作区时 MCP 参数命中敏感路径仍被门禁拦截', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate);
      final root = await Directory.systemTemp.createTemp('no-ws-gate-');
      try {
        // ~ 前缀展开 HOME 后命中 .ssh 黑名单（rootPath 为空不再整体短路）。
        expect(
          reg.mcpArgsHitDeniedZoneForTest(
            {'path': '~/.ssh/id_rsa'},
            rootPath: '',
          ),
          isTrue,
        );
        // file:// 绝对路径命中敏感段。
        final home = Platform.environment['HOME'] ?? '';
        if (home.isNotEmpty) {
          expect(
            reg.mcpArgsHitDeniedZoneForTest({
              'uri': 'file://$home/.ssh/id_rsa',
            }, rootPath: null),
            isTrue,
          );
        }
        // 非敏感路径不误伤。
        expect(
          reg.mcpArgsHitDeniedZoneForTest({
            'path': '/usr/share/doc/readme.md',
          }, rootPath: ''),
          isFalse,
        );
        // 有工作区时区外路径仍按原口径拒绝（回归不弱化）。
        expect(
          reg.mcpArgsHitDeniedZoneForTest(
            {'path': '/etc/passwd'},
            rootPath: root.path,
          ),
          isTrue,
        );
      } finally {
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('b2) 无工作区时 mcp_read_resource 敏感 file:// 直达被拒', () async {
      final gate = ApprovalGate();
      final reg = ToolRegistry(gate: gate);
      final home = Platform.environment['HOME'] ?? '';
      try {
        final r = await reg.executeWithGuards(
          toolName: 'mcp_read_resource',
          args: {'serverId': 's1', 'uri': 'file://$home/.ssh/id_rsa'},
          mode: AgentMode.agent,
          provider: provider(),
          model: AiModelOption(id: 'm'),
          rootPath: null,
          sessionId: 's',
        );
        expect(r?.ok, isFalse);
        expect(r?.output, contains('已按门禁拒绝'));
        expect(gate.pendingApproval, isNull);
      } finally {
        await reg.dispose();
        gate.dispose();
      }
    });

    test('c) _minimalEnv 不透传 NODE_PATH/PYTHONPATH', () {
      final env = McpSession.minimalEnvForTest();
      expect(env.containsKey('NODE_PATH'), isFalse);
      expect(env.containsKey('PYTHONPATH'), isFalse);
    });

    test('e) 备份恢复直写：加载时强制 enabled=false 并回写快照', () async {
      final restored = jsonEncode([
        {
          'id': 'restore-1',
          'name': 'restore-1',
          'enabled': true,
          'transport': 'stdio',
          'command': 'npx',
          'args': <String>['-y', 'some-server'],
          'env': <String, String>{},
        },
      ]);
      SharedPreferences.setMockInitialValues({
        // 恢复注入：数据与快照不一致（webdav 直写绕过 importRaw 门禁）。
        'mcpServers': restored,
        'mcpServersSnapshot': '[]',
      });
      await SettingsStore.init();
      final manager = McpManager.instance;
      await manager.ensureLoaded();
      // 与 importRaw 口径一致：恢复批一律禁用，用户逐个启用即明示同意；
      // 禁用态不会触发 connect。
      expect(manager.servers.single.enabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      final stored = jsonDecode(prefs.getString('mcpServers')!) as List;
      expect((stored.single as Map)['enabled'], isFalse);
      // 快照同步回写：下次启动不再重复走恢复分支。
      expect(prefs.getString('mcpServersSnapshot'), isNotNull);
      expect(
        prefs.getString('mcpServersSnapshot'),
        prefs.getString('mcpServers'),
      );
    });
  });

  group('前台输出环形缓冲', () {
    test('d) run_command 前台输出超 2000 行只保留尾部', () {
      final ring = ForegroundOutputRing();
      for (var i = 1; i <= 2500; i++) {
        ring.append('line$i\n');
      }
      expect(ring.isNotEmpty, isTrue);
      final text = ring.toString();
      expect(text, contains('仅保留尾部 2000 行'));
      expect(text, contains('line2500'));
      expect(text, contains('line501'));
      // 头部 500 行已丢弃。
      expect(text, isNot(contains('line500\n')));
      expect(text, isNot(contains('\nline1\n')));

      // 单行超 500 字截断保留尾部省略号。
      final long = ForegroundOutputRing();
      long.append('${'x' * 600}\n');
      final longText = long.toString();
      expect(longText.length, lessThan(600));
      expect(longText.endsWith('…'), isTrue);
    });
  });
}
