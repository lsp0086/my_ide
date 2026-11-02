import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_profiles.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/tool_registry.dart';

void main() {
  group('AgentProfile 白名单', () {
    test('architect/ask 为只读档，code/debug 不限制', () {
      final architect = AgentProfiles.byId('architect')!;
      final ask = AgentProfiles.byId('ask')!;
      final code = AgentProfiles.byId('code')!;
      final debug = AgentProfiles.byId('debug')!;
      expect(architect.allowedTools, isNotNull);
      expect(ask.allowedTools, isNotNull);
      expect(code.allowedTools, isNull);
      expect(debug.allowedTools, isNull);
    });

    test('只读集含读/搜索/诊断/git 只读与只读子Agent', () {
      final tools = AgentProfile.readOnlyTools;
      expect(tools, contains('read_file'));
      expect(tools, contains('list_files'));
      expect(tools, contains('search_text'));
      expect(tools, contains('get_diagnostics'));
      expect(tools, contains('git_status'));
      expect(tools, contains('spawn_subagent'));
    });

    test('只读集不含任何写/删/命令/浏览器/computer-use 工具', () {
      final tools = AgentProfile.readOnlyTools;
      for (final forbidden in [
        'write_file',
        'edit_file',
        'apply_patch',
        'run_command',
        'terminal_create',
        'terminal_write',
        'browser_click',
        'browser_fill',
        'computer_click',
        'fetch_url',
      ]) {
        expect(tools.contains(forbidden), isFalse, reason: forbidden);
      }
    });
  });

  group('ToolRegistry.schemas 的 profile 交集过滤', () {
    ToolRegistry buildRegistry() => ToolRegistry(gate: ApprovalGate());

    String toolNames(List<Map<String, dynamic>>? schemas) => schemas!
        .map((t) => '${(t['function'] as Map)['name']}')
        .join(',');

    test('profile 白名单收窄后只读工具保留、写工具消失', () {
      final registry = buildRegistry();
      final schemas = registry.schemas(
        AgentMode.agent,
        profileAllowedTools: AgentProfile.readOnlyTools,
      );
      final names = toolNames(schemas);
      expect(names, contains('read_file'));
      expect(names, contains('search_text'));
      expect(names, isNot(contains('write_file')));
      expect(names, isNot(contains('run_command')));
      // load_skill 恒保留（防锁死无法切档）。
      expect(names, contains('load_skill'));
    });

    test('profile 白名单为 null 时不改变默认集', () {
      final registry = buildRegistry();
      final schemas = registry.schemas(
        AgentMode.agent,
        profileAllowedTools: null,
      );
      final names = toolNames(schemas);
      expect(names, contains('write_file'));
      expect(names, contains('run_command'));
    });

    test('Plan 模式下 profile 过滤同样生效（只读本就收窄）', () {
      final registry = buildRegistry();
      final plan = registry.schemas(
        AgentMode.plan,
        profileAllowedTools: AgentProfile.readOnlyTools,
      );
      expect(plan, isNotNull);
      final names = toolNames(plan);
      // Plan 本就只读；profile 只读集是其子集语义。
      expect(names, contains('read_file'));
    });

    test('skill 与 profile 均受限时取交集', () {
      final registry = buildRegistry();
      // 模拟 skill 只允许 read_file/list_files（分桶）。
      registry.setSkillAllowed('sess-p1', {'read_file', 'list_files'});
      final schemas = registry.schemas(
        AgentMode.agent,
        sessionId: 'sess-p1',
        profileAllowedTools: AgentProfile.readOnlyTools,
      );
      final names = toolNames(schemas);
      // 交集：read_file/list_files 保留；profile 独有（search_text 等）剔除。
      expect(names, contains('read_file'));
      expect(names, contains('list_files'));
      expect(names, isNot(contains('search_text')));
      expect(names, isNot(contains('write_file')));
    });
  });
}
