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

  test('链式后段危险同样拒绝', () {
    // 此前只看首命令，`echo ok; rm -rf ~` 首段无害即整体放过。
    for (final c in [
      'echo ok; rm -rf ~',
      'echo ok && rm -rf /',
      'echo ok || rm -rf /*',
    ]) {
      expect(
        CommandPolicy.judge(c, rootPath: workspace.path),
        CommandVerdict.deny,
        reason: c,
      );
    }
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

  test('开源对齐的合法命令自动放行、写操作继续审批', () {
    // git 只读动词
    for (final c in [
      'git show HEAD',
      'git blame inside.txt',
      'git branch',
      'git tag',
      'git remote get-url origin',
      'git stash list',
      'git fetch origin',
      'git rev-parse HEAD',
      'git ls-files',
    ]) {
      expect(
        CommandPolicy.judge(c, rootPath: workspace.path),
        CommandVerdict.allow,
        reason: c,
      );
    }
    // git 写操作（branch/tag 带位置参数=创建，remote add/push 系同属写）
    for (final c in [
      'git branch new-name',
      'git tag v1',
      'git branch -d old',
      'git remote add origin x',
      'git stash push',
      'git push origin main',
      'git commit -m x',
      'git checkout main',
      // 命令执行类开关：--upload-pack 可在本地执行任意命令，必须走审批。
      'git fetch --upload-pack=touch escaped',
      'git fetch origin --upload-pack=touch escaped',
      'git clone --upload-pack=touch escaped x',
      // 写型格式化开关：--write/--fix 可静默改盘，必须走审批。
      'prettier --write inside.txt',
      'eslint --fix inside.txt',
    ]) {
      expect(
        CommandPolicy.judge(c, rootPath: workspace.path),
        CommandVerdict.approve,
        reason: c,
      );
    }
    // 文本/文件查看类
    for (final c in [
      'grep -rn foo inside.txt',
      'find . -name "*.dart"',
      'tree -L 2',
      'diff inside.txt inside.txt',
      'file inside.txt',
      'stat inside.txt',
      'du -sh .',
      'ps aux',
      'mkdir -p newdir/sub',
      'gh pr list',
      'gh issue view 1',
      'tsc --noEmit',
      'eslint inside.txt',
      'npm view react',
      'pnpm list',
      'docker compose ps',
    ]) {
      expect(
        CommandPolicy.judge(c, rootPath: workspace.path),
        CommandVerdict.allow,
        reason: c,
      );
    }
    // flutter/dart 本地构建测试（run/pub get 系写/网操作，继续审批）
    for (final c in ['flutter test', 'dart analyze']) {
      expect(
        CommandPolicy.judge(c, rootPath: workspace.path),
        CommandVerdict.allow,
        reason: c,
      );
    }
    // 写/网/危险操作继续审批或拒绝（mkdir 无 -p 即可能覆盖，继续审批）
    final notAllowed = [
      'npm install foo',
      'npm publish',
      'docker compose up',
      'docker build .',
      'flutter pub get',
      'dart run main.dart',
      'sed -i s/a/b/ inside.txt',
      'awk {print} inside.txt',
      'mkdir newdir',
      'cat ../outside.txt',
    ];
    for (final c in notAllowed) {
      final verdict = CommandPolicy.judge(c, rootPath: workspace.path);
      expect(verdict, isNot(CommandVerdict.allow), reason: c);
    }
    // 敏感文件走读审批（approve 非 allow）：门禁仍在，只是不弹窗直放。
    expect(
      CommandPolicy.judge('grep foo ~/.ssh/id_rsa', rootPath: workspace.path),
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
