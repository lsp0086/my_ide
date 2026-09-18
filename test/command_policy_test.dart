import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/fs/workspace_fs.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('command-policy-');
    await File('${workspace.path}/inside.txt').writeAsString('inside');
  });

  tearDown(() async {
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  });

  test('只自动放行可直接执行的固定命令与参数', () {
    final invocation = CommandPolicy.safeInvocation(
      'cat "inside.txt"',
      rootPath: workspace.path,
    );

    expect(invocation, isNotNull);
    expect(invocation!.executable, 'cat');
    expect(invocation.arguments, ['inside.txt']);
    expect(
      CommandPolicy.judge('git status', rootPath: workspace.path),
      CommandVerdict.allow,
    );
    expect(
      CommandPolicy.judge('echo hello world', rootPath: workspace.path),
      CommandVerdict.allow,
    );
    expect(
      CommandPolicy.judge('git branch new-name', rootPath: workspace.path),
      CommandVerdict.approve,
    );
    expect(
      CommandPolicy.judge(
        'git diff --no-index inside.txt ../outside.txt',
        rootPath: workspace.path,
      ),
      CommandVerdict.approve,
    );
    expect(
      CommandPolicy.judge(
        'git diff -- ../outside.txt',
        rootPath: workspace.path,
      ),
      CommandVerdict.approve,
    );
  });

  test('Shell 元字符、替换、展开和换行一律要求审批', () {
    final commands = [
      'echo ok; touch escaped',
      'echo ok && touch escaped',
      'echo ok || touch escaped',
      'echo ok | cat',
      'echo ok > escaped',
      r'echo $(touch escaped)',
      'echo `touch escaped`',
      'echo ok\ntouch escaped',
      r'echo $HOME',
      r'echo ${HOME}',
    ];

    for (final command in commands) {
      expect(
        CommandPolicy.judge(command, rootPath: workspace.path),
        CommandVerdict.approve,
        reason: command,
      );
      expect(
        CommandPolicy.safeInvocation(command, rootPath: workspace.path),
        isNull,
        reason: command,
      );
    }
  });

  test('工作区外路径和敏感路径不自动放行', () {
    final outside = '${workspace.parent.path}/outside.txt';
    expect(
      CommandPolicy.judge('cat "$outside"', rootPath: workspace.path),
      CommandVerdict.approve,
    );
    expect(
      CommandPolicy.judge('cat ../outside.txt', rootPath: workspace.path),
      CommandVerdict.approve,
    );
    expect(
      CommandPolicy.judge('cat .env', rootPath: workspace.path),
      CommandVerdict.approve,
    );
  });

  test('未审批执行器拒绝 Shell 命令且不产生副作用', () async {
    final escaped = File('${workspace.path}/escaped');
    final result = await AgentTools(
      rootPath: workspace.path,
    ).execute('run_command', {'command': 'echo ok > escaped'});

    expect(result.ok, isFalse);
    expect(result.output, contains('必须经逐次审批'));
    expect(await escaped.exists(), isFalse);
  });

  test('引号内元字符通过固定 executable 和 argv 作为普通文本执行', () async {
    final result = await AgentTools(
      rootPath: workspace.path,
    ).execute('run_command', {'command': 'echo "safe; literal"'});

    expect(result.ok, isTrue);
    expect(result.output, contains('safe; literal'));
    expect(await File('${workspace.path}/literal').exists(), isFalse);
  });
}
