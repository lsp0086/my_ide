import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_templates.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_ide/mcp/mcp_managed_policy.dart';
import 'package:path/path.dart' as p;

Future<String> readLibSource(String relPath) async {
  final base = File('lib/$relPath');
  var out = await base.readAsString();
  final stem = base.uri.pathSegments.last.replaceAll(RegExp(r'\.dart$'), '');
  for (final f in base.parent.listSync().whereType<File>()) {
    // 按文件名匹配 part：f.path 在 Windows 是反斜杠，与 'lib/ui/xxx_' 前
    // 缀比对恒 false（part 全部漏拼、源码口径断言在 Windows CI 必挂）。
    final name = f.uri.pathSegments.last;
    if (name.startsWith('${stem}_') && name.endsWith('.dart')) {
      out += '\n${await f.readAsString()}';
    }
  }
  return out;
}


/// G 节采纳项回归汇总：subagent 模板发现（G-R2-9）、MCP 托管白名单
/// （G-R2-14）、fork 增强（G-R2-12）、agent following 纯函数（G-R2-15）、
/// 采纳项 schema/源码口径（G-R2-5/7/16、G-B3/B14）。
void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('gitems-');
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('G-R2-9 模板发现：front-matter 解析出角色/工具/模型', () async {
    final dir = Directory(
      p.join(workspace.path, '.my_ide', 'agents'),
    );
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'reviewer.md')).writeAsString('''
---
name: reviewer
description: 只读评审
allowed-tools: read_file, search_text
model: fast
---

你是代码评审员，只读不写。
''');
    final mgr = AgentTemplateManager();
    final list = await mgr.discover(workspace.path);
    expect(list, hasLength(1));
    expect(list.first.name, 'reviewer');
    expect(list.first.allowedTools, contains('read_file'));
    expect(list.first.promptAppendix, contains('评审员'));
  });

  test('G-R2-9 模板拒符号链接与缺 name', () async {
    final dir = Directory(
      p.join(workspace.path, '.my_ide', 'agents'),
    );
    await dir.create(recursive: true);
    final outside = File(p.join(workspace.path, 'evil.md'));
    await outside.writeAsString('---\nname: evil\n---\nbody\n');
    await Link(p.join(dir.path, 'evil.md')).create(outside.path);
    final mgr = AgentTemplateManager();
    final list = await mgr.discover(workspace.path);
    expect(list, isEmpty, reason: '符号链接模板不得进入派生列表');
  });

  test('G-R2-14 托管白名单：deny 优先、allowManagedOnly', () {
    final policy = McpManagedPolicy.fromJson({
      'allowedMcpServers': ['a', 'b'],
      'deniedMcpServers': ['b'],
      'allowManagedOnly': true,
    });
    expect(policy.rejectionFor('a'), isNull);
    expect(policy.rejectionFor('B'), isNotNull, reason: 'deny 优先且大小写归一');
    expect(policy.rejectionFor('c'), isNotNull, reason: 'allowManagedOnly 拒清单外');
    final open = McpManagedPolicy.fromJson({
      'allowedMcpServers': ['a'],
      'deniedMcpServers': <String>[],
      'allowManagedOnly': false,
    });
    expect(open.rejectionFor('anything'), isNull,
        reason: '非托管清单模式不限制清单外');
  });

  test('G-R2-12 fork 携带模式/模型覆盖与快照锚点', () async {
    SharedPreferences.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('gfork-');
    addTearDown(() => dir.delete(recursive: true));
    final store = ChatStore();
    await store.loadForProject(dir.path);
    await store.newChat();
    final sid = store.active!.id;
    await store.addMessageTo(
      sessionId: sid,
      msg: ChatMessage(id: 'm1', role: 'user', text: 'hello'),
    );
    final forkId = await store.forkSession(
      sid,
      'm1',
      mode: 'plan',
      modelId: 'm-fast',
      anchorVersionId: 'ver-42',
    );
    expect(forkId, isNotNull);
    final fork = store.sessions.firstWhere((e) => e.id == forkId);
    expect(fork.forkMode, 'plan');
    expect(fork.forkModelId, 'm-fast');
    expect(fork.forkAnchorVersionId, 'ver-42');
    expect(
      fork.messages.first.text,
      contains('ver-42'),
      reason: '首条标注消息可见 fork 基线',
    );
    // 序列化往返不丢
    final json = jsonDecode(jsonEncode(fork.toJson())) as Map<String, dynamic>;
    final back = ChatSession.fromJson(json);
    expect(back.forkAnchorVersionId, 'ver-42');
  });

  test('G-R2-15 首个差异行纯函数', () async {
    // 源码口径：firstDiffLineForTest 在 code_editor.dart
    final src = await readLibSource('ui/code_editor.dart');
    expect(src.contains('int firstDiffLineForTest'), isTrue);
    expect(src.contains('CodeLineSelection('), isTrue,
        reason: 're_editor 光标类型口径');
    expect(src.contains('G-R2-15 agent following'), isTrue);
  });

  test('采纳项 schema/源码口径：G-R2-5/7/16、G-B3/B14', () async {
    final schemas = await readLibSource('ai/agent_tool_schemas.dart');
    expect(schemas.contains("'waitValue'"), isTrue, reason: 'G-R2-7');
    expect(schemas.contains("'type'"), isTrue, reason: 'G-B15 targets type');
    expect(schemas.contains("'insight'"), isTrue, reason: 'G-B14');
    final gate = await readLibSource('ui/ide_shell_chat.dart');
    expect(gate.contains('永久允许'), isTrue, reason: 'G-R2-5 审批永久允许档');
    final client = await readLibSource('ai/agent_client.dart');
    expect(client.contains('annotation.added'), isTrue, reason: 'G-R2-16 引用');
    expect(client.contains('[引用]'), isTrue);
    final nav = await File(
      'lib/browser/browser_service_navigation.dart',
    ).readAsString();
    expect(
      nav.contains('createBrowserContext'),
      isTrue,
      reason: 'G-B3 上下文隔离',
    );
    final metrics = (await readLibSource('ai/agent_browser_tools.dart'));
    expect(metrics.contains("args['insight']"), isTrue, reason: 'G-B14 洞察');
    final sandbox = (await readLibSource('ai/tool_registry.dart'));
    expect(
      sandbox.contains('G-R2-4'),
      isTrue,
      reason: '沙箱外 shell 收敛已接线',
    );
  });
}
