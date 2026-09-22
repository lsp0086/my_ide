import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/lsp/lsp_client.dart';
import 'package:my_ide/lsp/symbol_index.dart';
import 'package:my_ide/mcp/mcp_config.dart';
import 'package:my_ide/skills/skill_manager.dart';

void main() {
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

  test('MCP env 展开支持两种占位', () {
    final env = {'A': 'hello', 'B': 'world'};
    expect(McpConfigImporter.expandEnv(r'${A}-x', env), 'hello-x');
    expect(McpConfigImporter.expandEnv(r'${ENV:B}-y', env), 'world-y');
    expect(McpConfigImporter.expandEnv(r'${MISSING}-z', env), '-z');
    expect(
      McpConfigImporter.expandEnvMap({'k': r'token-${A}'}, env)['k'],
      'token-hello',
    );
  });

  test('MCP 配置校验缺 command/url 告警', () {
    final badStdio = McpServerConfig(id: 's1', name: 's1', command: '');
    expect(McpConfigImporter.validateConfig(badStdio), isNotEmpty);
    final badHttp = McpServerConfig(
      id: 's2',
      name: 's2',
      transport: McpTransportType.http,
      url: '',
    );
    expect(McpConfigImporter.validateConfig(badHttp), isNotEmpty);
    final ok = McpServerConfig(id: 's3', name: 's3', command: 'npx');
    expect(McpConfigImporter.validateConfig(ok), isEmpty);
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

  test('skill 校验缺文件与未知工具告警', () async {
    final dir = await Directory.systemTemp.createTemp('skill-bad-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final missing = await SkillManager.validateSkillDir(dir.path);
    expect(missing.join(), contains('SKILL.md'));

    await File('${dir.path}/SKILL.md').writeAsString(
      '---\nname: demo-skill\ndescription: demo\nallowed-tools: read_file, no-such-tool\n---\n\nbody\n',
    );
    final warnings = await SkillManager.validateSkillDir(dir.path);
    expect(warnings.join(), contains('未知项'));
    expect(SkillManager.skillTemplate('demo'), contains('demo'));
  });

  test('轨迹导出含消息与版本ID', () async {
    final root = await Directory.systemTemp.createTemp('traj-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = ChatStore();
    await store.loadForProject(root.path);
    await store.newChat();
    final session = store.active!;
    await store.addMessageTo(
      sessionId: session.id,
      msg: ChatMessage(
        role: 'assistant',
        text: 'done',
        files: const ['a.dart'],
        afterVersionId: 'v123',
      ),
    );
    final md = store.exportTrajectoryMarkdown(session.id);
    expect(md, contains('done'));
    expect(md, contains('a.dart'));
    expect(md, contains('v123'));
    expect(store.exportTrajectoryMarkdown('missing'), isEmpty);
  });
}
