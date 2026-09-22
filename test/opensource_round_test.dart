import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/diagnostics/app_logger.dart';
import 'package:my_ide/lsp/language_servers.dart';
import 'package:my_ide/prompts/prompt_templates.dart';
import 'package:my_ide/version/checkpoint_store.dart';
import 'package:my_ide/workspace/workspace_search.dart';

SearchFileGroup fileGroup(String rel, List<String> lines) =>
    SearchFileGroup(
      absolutePath: '/root/$rel',
      relativePath: rel,
      hits: [
        for (var i = 0; i < lines.length; i++)
          SearchHit(
            absolutePath: '/root/$rel',
            relativePath: rel,
            line: i,
            column: 0,
            lineText: lines[i],
            matchLength: 3,
          ),
      ],
    );

void main() {
  group('P1: 工作区搜索', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('workspace-search-');
      await Directory('${root.path}/lib').create();
      await Directory('${root.path}/ignored').create();
      await File('${root.path}/.gitignore').writeAsString('ignored/\\n*.log\\n');
      await File('${root.path}/lib/keep.dart').writeAsString('needle here\\n');
      await File('${root.path}/ignored/no.dart').writeAsString('needle here\\n');
      await File('${root.path}/skip.log').writeAsString('needle here\\n');
    });

    tearDown(() async {
      // Windows 下文件句柄释放有延迟（杀毒软件/索引/刚关闭的 isolate），
      // 直接删临时目录可能报 errno 32，按指数退避重试后仍失败则放弃，
      // 避免清理问题误判为功能失败。
      for (var i = 0; i < 5; i++) {
        try {
          if (await root.exists()) await root.delete(recursive: true);
          break;
        } catch (_) {
          if (i == 4) break;
          await Future<void>.delayed(Duration(milliseconds: 100 * (i + 1)));
        }
      }
    });

    test('glob 和 .gitignore 过滤文件', () async {
      final groups = await WorkspaceSearch.search(
        rootPath: root.path,
        query: 'needle',
        glob: 'lib/**/*.dart',
      );
      expect(groups.map((group) => group.relativePath), ['lib/keep.dart']);
    });

    test('支持取消和纯函数替换', () async {
      final token = SearchCancellationToken()..cancel();
      expect(await WorkspaceSearch.search(
        rootPath: root.path,
        query: 'needle',
        cancellationToken: token,
      ), isEmpty);
      expect(WorkspaceSearch.replace('abc abc', 'abc', 'x'), 'x abc');
      expect(WorkspaceSearch.replaceAll('abc abc', 'abc', 'x'), 'x x');
    });
  });

  group('R1: 搜索相关性排序', () {
    test('文件名命中排首', () {
      final groups = [
        fileGroup('lib/deep/nested/other.dart', ['foo bar']),
        fileGroup('lib/foo.dart', ['class Foo {', '  foo bar']),
      ];
      final ranked = WorkspaceSearch.rankGroups(groups, 'foo');
      expect(ranked.first.relativePath, 'lib/foo.dart');
    });

    test('空查询保持原序', () {
      final groups = [fileGroup('b.dart', ['x']), fileGroup('a.dart', ['x'])];
      final ranked = WorkspaceSearch.rankGroups(groups, '  ');
      expect(ranked.map((g) => g.relativePath), ['b.dart', 'a.dart']);
    });
  });

  group('R2: 命令信任 key', () {
    test('trustCurrentAndApprove 记住本轮 key', () async {
      final gate = ApprovalGate();
      expect(gate.isTrusted('flutter test'), isFalse);
      // 无待审批时调用等同普通通过，不崩
      gate.trustCurrentAndApprove();
      gate.beginRun();
      final future = gate.askApproval(PendingApproval(
        kind: 'command',
        title: '执行命令',
        detail: '\$ flutter test',
        trustKey: 'flutter test',
      ));
      // 信任当前并通过
      gate.trustCurrentAndApprove();
      expect(await future, isTrue);
      expect(gate.isTrusted('flutter test'), isTrue);
      expect(gate.isTrusted('git status'), isFalse);
      expect(gate.isTrusted(null), isFalse);
      gate.dispose();
    });
  });

  group('R3: git 快照', () {
    test('非仓库返回空记录不抛错', () async {
      final dir = await Directory.systemTemp.createTemp('nogit-');
      try {
        final snap = await GitSnapshot.capture(dir.path);
        expect(snap.hasRepo, isFalse);
        expect(snap.branch, isNull);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('CheckpointInfo git 字段 JSON 往返', () {
      final info = CheckpointInfo(
        id: 'abc',
        message: 'm',
        createdAt: DateTime(2026, 1, 1),
        kind: 'manual',
        files: const [],
        gitBranch: 'main',
        gitCommit: 'deadbee',
        gitDirty: true,
      );
      final back = CheckpointInfo.fromJson(info.toJson());
      expect(back.gitBranch, 'main');
      expect(back.gitCommit, 'deadbee');
      expect(back.gitDirty, isTrue);
      // 旧 manifest 无 git 字段也能解析
      final legacy = CheckpointInfo.fromJson({
        'id': 'x',
        'message': 'm',
        'createdAt': '2026-01-01T00:00:00.000',
        'kind': 'manual',
        'files': [],
      });
      expect(legacy.gitBranch, isNull);
    });
  });

  group('R5: 会话分叉与模板', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('fork-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('fork 截断复制并断掉 response 链', () async {
      final store = ChatStore();
      await store.loadForProject(root.path);
      await store.newChat();
      final sid = store.active!.id;
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: 'q1'),
      );
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(
          role: 'assistant',
          text: 'a1',
          responsesResponseId: 'resp-123',
        ),
      );
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: 'q2'),
      );
      final firstUser = store.sessionById(sid)!.messages.first;
      final newId = await store.forkSession(sid, firstUser.id);
      expect(newId, isNotNull);
      final forked = store.sessionById(newId!);
      expect(forked, isNotNull);
      expect(forked!.messages, hasLength(1));
      expect(forked.title, contains('分支'));
      // 原会话不动
      expect(store.sessionById(sid)!.messages, hasLength(3));
      store.dispose();

      // 落盘可恢复
      final reloaded = ChatStore();
      await reloaded.loadForProject(root.path);
      expect(reloaded.sessionById(newId)!.messages, hasLength(1));
      reloaded.dispose();
    });

    test('fork 断 response 链：复制消息无 responsesResponseId', () async {
      final store = ChatStore();
      await store.loadForProject(root.path);
      await store.newChat();
      final sid = store.active!.id;
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: 'q'),
      );
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(
          role: 'assistant',
          text: 'a',
          responsesResponseId: 'resp-xyz',
        ),
      );
      final session = store.sessionById(sid)!;
      final newId = await store.forkSession(sid, session.messages.last.id);
      final forked = store.sessionById(newId!)!;
      expect(forked.messages, hasLength(2));
      for (final m in forked.messages) {
        expect(m.responsesResponseId, isNull);
      }
      store.dispose();
    });

    test('fork 不存在的消息返回 null', () async {
      final store = ChatStore();
      await store.loadForProject(root.path);
      await store.newChat();
      final sid = store.active!.id;
      await store.addMessageTo(
        sessionId: sid,
        msg: ChatMessage(role: 'user', text: 'q'),
      );
      expect(await store.forkSession(sid, 'no-such-id'), isNull);
      expect(await store.forkSession('no-session', 'x'), isNull);
      store.dispose();
    });

    test('模板 render 占位与追加', () {
      const tpl = PromptTemplate(name: 't', body: '做这个：{{input}}');
      expect(tpl.render('修 bug'), '做这个：修 bug');
      const plain = PromptTemplate(name: 'p', body: '前缀');
      expect(plain.render('输入'), '前缀\n\n输入');
      expect(plain.render(''), '前缀');
      expect(PromptTemplateStore.builtins, isNotEmpty);
    });

    test('项目模板目录缺失返回空', () async {
      expect(await PromptTemplateStore.loadProject(root.path), isEmpty);
      expect(await PromptTemplateStore.loadProject(null), isEmpty);
    });
  });

  group('R6: 日志缓冲', () {
    test('内存保留最近条目', () {
      AppLogger.instance.info('t', 'hello');
      AppLogger.instance.warn('t', 'careful');
      AppLogger.instance.error('t', 'boom', StateError('x'));
      final recent = AppLogger.instance.recent;
      expect(recent.length, greaterThanOrEqualTo(3));
      expect(recent.last.level, 'E');
      expect(recent.last.message, 'boom');
    });
  });

  group('R10: 自定义 LSP 解析', () {
    test('custom 工厂规范化后缀', () {
      final spec = LanguageServerSpec.custom({
        'id': 'vue-ls',
        'label': 'Vue',
        'extensions': ['vue', '.svelte'],
        'command': 'vue-language-server',
        'args': ['--stdio'],
      });
      expect(spec.extensions, contains('.vue'));
      expect(spec.extensions, contains('.svelte'));
      expect(spec.autoInstall, isFalse);
    });
  });
}
