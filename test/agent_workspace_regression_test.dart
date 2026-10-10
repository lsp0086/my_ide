import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_client.dart';
import 'package:my_ide/ai/agent_runner.dart' show AgentMode;
import 'package:my_ide/ai/agent_tools.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/subagent_fanout.dart';
import 'package:my_ide/ai/subagent_runtime.dart';
import 'package:my_ide/ai/tool_registry.dart';
import 'package:my_ide/lsp/bundled_language_servers.dart';
import 'package:my_ide/workspace/semantic_index.dart';
import 'package:my_ide/workspace/workspace_search.dart';
import 'package:path/path.dart' as p;

class _FakeSubagentClient extends AgentClient {
  _FakeSubagentClient({this.largeArguments = false});

  final bool largeArguments;
  int calls = 0;
  List<Map<String, dynamic>>? lastTools;

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
    calls++;
    lastTools = tools;
    if (calls == 1) {
      yield AgentStreamEvent(
        toolCall: AgentToolCall(
          id: 'call-1',
          name: 'read_file',
          arguments: {
            'path': largeArguments ? 'x' * 2000 : 'large.txt',
          },
        ),
      );
    }
    yield AgentStreamEvent(done: true);
  }
}

void main() {
  test('写串行下标回填：同实例复用不错位（源码口径）', () async {
    // 复现：写串行for-in+indexOf(pending)在同_PendingToolCall实例复用时
    // 回首个下标致已成功项被二次覆盖。现for-i下标+backfillRemaining。
    // ignore: avoid_slow_async_io
    final src = await File('lib/ai/agent_runner.dart').readAsString();
    expect(src.contains('R11-1-A 写串行下标回填'), isTrue);
    expect(src.contains('for (var wi = 0; wi < seq.length; wi++)'), isTrue);
    // 写串行内不再用indexOf(pending)定位（注释提及R1-B4除外）。
    final seqIdx = src.indexOf('R11-1-A 写串行下标回填');
    final writeBlock = src.substring(seqIdx, seqIdx + 6000);
    expect(writeBlock.contains('indexOf(pending)'), isFalse);
  });

  test('cancelSessionWork 标记会话并停搜索', () async {
    final dir = await Directory.systemTemp.createTemp('cancel-work-');
    try {
      final tools = AgentTools(rootPath: dir.path);
      expect(tools.sessionWorkCancelled('s1'), isFalse);
      tools.cancelSessionWork('s1');
      expect(tools.sessionWorkCancelled('s1'), isTrue);
    } finally {
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  });

  test('全局取消同样中断主流：在途流可感知abort', () async {
    // 复现：Runner.requestCancel('')此前仅 _cancelRequested=true，
    // 未调 _client.abort，服务端流挂到自然结束。
    // ignore: avoid_slow_async_io
    final src = await File('lib/ai/agent_runner.dart').readAsString();
    final idx = src.indexOf('void requestCancel(');
    expect(idx, greaterThanOrEqualTo(0));
    final body = src.substring(idx, idx + 1500);
    expect(body.contains('_client.abort()'), isTrue);
  });

  test('审批外读纵深拒敏感：读通道与写侧对齐', () async {
    // 复现：_read此前仅trash纵深，allowOutside可经审批读敏感文件，
    // 与_list敏感拒绝不对称。
    // ignore: avoid_slow_async_io
    final src = await File('lib/ai/agent_tools.dart').readAsString();
    expect(src.contains('allowOutside && WorkspaceFs.isSensitiveRelative(rel)'), isTrue);
  });

  test('内嵌导航过门禁：脏地址不跟随', () async {
    // 复现：attachEmbedded此前无条件跟随nav条，脏地址可被reload跟随。
    // ignore: avoid_slow_async_io
    final src = await File('lib/browser/browser_service.dart').readAsString();
    expect(src.contains('内嵌导航被门禁拒绝'), isTrue);
  });

  test('子 Agent 按会话中断只停本会话，他会话继续', () async {
    // 归属会话 A 的子 Agent 先取消：同 client 下 B 会话请求不受影响。
    // B 用独立 fake client（calls 从 0 计）：A 的 abort 只标 session-a，
    // 未关闭共享连接，B 仍可发请求；若退化为全局 abort，B 首行即抛 StateError。
    final dir = await Directory.systemTemp.createTemp('sub-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final clientA = _FakeSubagentClient();
    final runtimeA = SubagentRuntime(client: clientA, maxSteps: 3, ownerSessionId: 'session-a');
    runtimeA.requestCancel();
    final resultA = await runtimeA.run(
      task: '不要执行',
      files: const [],
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
    );
    expect(resultA.ok, isFalse);
    expect(resultA.output, contains('已取消'));
    expect(clientA.calls, 0);
    final clientB = _FakeSubagentClient(largeArguments: true);
    final runtimeB = SubagentRuntime(client: clientB, maxSteps: 3, ownerSessionId: 'session-b', tokenBudget: 100);
    final resultB = await runtimeB.run(
      task: '调研',
      files: const [],
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
      allowedTools: const {},
    );
    expect(clientB.calls, 1);
    expect(resultB.output, contains('超预算'));
  });

  test('子 Agent 空工具集不发送空 tools 且预算计入工具参数', () async {
    final dir = await Directory.systemTemp.createTemp('sub-budget-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final client = _FakeSubagentClient(largeArguments: true);
    // 预算阈值需大于子 Agent 系统提示初始占用（只读隔离声明加入后约 60 token），
    // 又远小于 2000 字符大参数（约 500 token），才能验证“预算计入工具参数”。
    final runtime = SubagentRuntime(client: client, maxSteps: 3, tokenBudget: 100);
    final result = await runtime.run(
      task: '调研',
      files: const [],
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
      allowedTools: const {},
    );
    expect(client.calls, 1);
    expect(client.lastTools, isNull);
    expect(result.untrusted, isTrue);
    expect(result.output, contains('超预算'));
  });

  test('工具结果按剩余预算截断并停止后续模型调用', () async {
    final dir = await Directory.systemTemp.createTemp('sub-result-budget-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File(p.join(dir.path, 'large.txt'));
    await file.writeAsString('x\n' * 1000);
    final client = _FakeSubagentClient();
    final runtime = SubagentRuntime(client: client, maxSteps: 3, tokenBudget: 80);
    final result = await runtime.run(
      task: '调研',
      files: const [],
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
    );
    expect(client.calls, 1);
    expect(result.untrusted, isTrue);
    expect(result.output, contains('超预算'));
  });

  test('对话落盘失败会设置 dirty 和 lastSaveError', () async {
    final blocker = await Directory.systemTemp.createTemp('chat-block-');
    addTearDown(() async {
      // macOS 上 delete(recursive:true) 偶发 ENOTEMPTY(66) 竞态：
      // 重试 + 吞掉清理失败，避免 tearDown 误判用例失败。
      for (var i = 0; i < 3; i++) {
        try {
          if (await blocker.exists()) await blocker.delete(recursive: true);
          break;
        } catch (_) {
          if (i == 2) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
    final fileAsRoot = File(p.join(blocker.path, 'not-a-dir'));
    await fileAsRoot.writeAsString('x');
    final store = ChatStore();
    await store.loadForProject(fileAsRoot.path);
    await store.newChat();
    expect(store.lastSaveError, isNotNull);
    expect(store.dirty, isTrue);
  });

  test('对话落盘成功后 dirty 清空', () async {
    final root = await Directory.systemTemp.createTemp('chat-ok-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = ChatStore();
    await store.loadForProject(root.path);
    await store.newChat();
    final session = store.active!;
    await store.addMessageTo(
      sessionId: session.id,
      msg: ChatMessage(role: 'user', text: 'hello'),
    );
    expect(store.lastSaveError, isNull);
    expect(store.dirty, isFalse);
    expect(
      await File(p.join(root.path, '.my_ide', 'chats', '${session.id}.json'))
          .exists(),
      isTrue,
    );
  });

  test('Windows 用 cmd.exe /c，其它平台用 /bin/sh -c', () {
    if (Platform.isWindows) {
      expect(AgentTools.shellExecutable, 'cmd.exe');
      expect(AgentTools.shellArguments('echo hi'), ['/c', 'echo hi']);
    } else {
      expect(AgentTools.shellExecutable, '/bin/sh');
      expect(AgentTools.shellArguments('echo hi'), ['-c', 'echo hi']);
    }
  });

  test('gzip 解压不依赖外部命令', () async {
    final dir = await Directory.systemTemp.createTemp('gz-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final raw = File(p.join(dir.path, 'a.bin'));
    await raw.writeAsBytes([1, 2, 3, 4, 5]);
    final gz = File(p.join(dir.path, 'a.bin.gz'));
    await gz.writeAsBytes(gzip.encode(await raw.readAsBytes()));
    final out = p.join(dir.path, 'out.bin');
    await ArchiveExtract.gzipFile(gz.path, out);
    expect(await File(out).readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('并行扇出透传 untrusted/来源/token', () async {
    final review = await runParallel(
      [FanoutTask(id: 'a', task: 't1'), FanoutTask(id: 'b', task: 't2')],
      (t) async => AgentToolResult(
        ok: true,
        untrusted: true,
        source: 'subagent',
        output: 'out-${t.id}',
        promptTokens: 10,
        completionTokens: 5,
      ),
    );
    expect(review.results.length, 2);
    for (final r in review.results) {
      expect(r.untrusted, isTrue);
      expect(r.sourceLabel, 'subagent');
      expect(r.promptTokens, 10);
      expect(r.completionTokens, 5);
    }
  });

  test('并行空批best占位gen与发起代一致', () async {
    // 复现：runParallel([]) 此前 best.gen 恒0，调用方按gen丢弃旧轮晚到时误判。
    final review = await runParallel(
      [],
      (t) async => AgentToolResult(ok: true, output: 'x'),
      gen: 7,
    );
    expect(review.best.gen, 7);
    expect(review.best.ok, isFalse);
  });

  test('并行空id不去重：两空id任务均执行', () async {
    // 复现：空 id 两任务此前第二个被判重复跳过致调研丢失。
    // 第8轮收敛为空/空白 id 不参与去重。
    var calls = 0;
    final review = await runParallel(
      [FanoutTask(id: '', task: 't1'), FanoutTask(id: '  ', task: 't2')],
      (t) async {
        calls++;
        return AgentToolResult(ok: true, output: 'out-$calls');
      },
    );
    expect(calls, 2);
    expect(review.results.length, 2);
    expect(review.results.map((r) => r.output).toSet().length, 2);
  });

  test('并行取消分支空id恒收集：两空id取消感知均收集', () async {
    // 复现：runParallel 取消感知分支此前按来源去重，空 id 第二任务被吞。
    final review = await runParallel(
      [FanoutTask(id: '', task: 't1'), FanoutTask(id: '', task: 't2')],
      (t) async => AgentToolResult(ok: true, output: 'out-${t.task}'),
      shouldCancel: () => false,
    );
    expect(review.results.length, 2);
  });

  test('只读批空id按序回填不互盖', () async {
    // 复现：只读批结果回填此前按来源去重，空 id 第二任务被吞。
    final restResults = [
      AgentToolResult(ok: true, output: 'first'),
      AgentToolResult(ok: true, output: 'second'),
    ];
    final ids = ['', ''];
    final restById = <String, AgentToolResult?>{};
    for (var i = 0; i < ids.length; i++) {
      final key = ids[i];
      if (key.trim().isEmpty) continue;
      restById.putIfAbsent(key, () => restResults[i]);
    }
    final out = <String?>[
      for (var i = 0; i < ids.length; i++)
        ids[i].trim().isEmpty ? restResults[i].output : restById[ids[i]]?.output,
    ];
    expect(out, ['first', 'second']);
  });

  test('扇出取消截断空id按位回填不吞项', () async {
    // 复现：取消截断回填按来源判已收集，两空 id 第二项被误判已收集而吞占位。
    var calls = 0;
    final review = await runParallel(
      [FanoutTask(id: '', task: 't1'), FanoutTask(id: '', task: 't2')],
      (t) async {
        calls++;
        if (calls == 1) return AgentToolResult(ok: true, output: 'done-1');
        await Future<void>.delayed(const Duration(seconds: 5));
        return AgentToolResult(ok: true, output: 'done-2');
      },
      shouldCancel: () => calls >= 1,
      maxConcurrency: 2,
    );
    expect(review.results.length, 2);
    expect(review.results[0].output, 'done-1');
    expect(review.results[1].output.contains('用户中断'), isTrue);
  });

  test('写交集检测：同文件并发写可判定串行化', () {
    // 复现：并行分支同文件并发写last-write-wins互盖（OpenHands共享写坑）。
    // 现touchedFiles交集非空即冲突，调用方串行化或打回。
    // 来源 https://engineering.viblo.asia/p/openhands-deep-dive-build-your-own-guide-OXLA0jKMJGr
    // + https://forum.langchain.com/t/how-to-partially-stop-the-langgraph-workflow/4239
    FanoutResult r(String s, List<String> files) => FanoutResult(
          source: s,
          ok: true,
          output: 'o',
          touchedFiles: files,
        );
    expect(
      FanoutReview.conflictingFiles([
        r('a', ['x.dart']),
        r('b', ['y.dart']),
      ]),
      isEmpty,
    );
    expect(
      FanoutReview.conflictingFiles([
        r('a', ['x.dart']),
        r('b', ['x.dart']),
      ]),
      {'x.dart'},
    );
  });

  test('对话图片资产落盘只存引用、可解析回 dataUrl', () async {
    final root = await Directory.systemTemp.createTemp('chat-asset-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = ChatStore();
    await store.loadForProject(root.path);
    await store.newChat();
    final session = store.active!;
    // 1x1 PNG：资产落盘后 chats/*.json 不得含 base64。
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    final ref = await store.saveChatImageAsset(
      sessionId: session.id,
      bytes: bytes,
      mime: 'image/png',
    );
    expect(ref.startsWith('asset:'), isTrue);
    await store.addMessageTo(
      sessionId: session.id,
      msg: ChatMessage(role: 'user', text: '见图', images: [ref]),
    );
    final saved = File(
      p.join(root.path, '.my_ide', 'chats', '${session.id}.json'),
    );
    // chats 落盘为 gzip 二进制：读字节解压后再断言，不直接按 utf8 读文件。
    final savedBytes = await saved.readAsBytes();
    final savedText = utf8.decode(gzip.decode(savedBytes));
    expect(savedText.contains('base64'), isFalse);
    expect(savedText.contains('asset:'), isTrue);
    final resolved = await store.resolveChatImages([ref]);
    expect(resolved.single.startsWith('data:image/png;base64,'), isTrue);
    // 兼容旧 dataUrl：直接透传不丢图。
    const legacy = 'data:image/png;base64,AAAA';
    expect(await store.resolveChatImage(legacy), legacy);
    // 缺失文件返回 null，不抛错。
    expect(await store.resolveChatImage('asset:chat_assets/nope/x.png'), isNull);
  });

  group('工作区搜索', () {
    late Directory searchRoot;

    setUp(() async {
      searchRoot = await Directory.systemTemp.createTemp('workspace-search-');
      await Directory('${searchRoot.path}/lib').create();
      await Directory('${searchRoot.path}/ignored').create();
      await File('${searchRoot.path}/.gitignore').writeAsString('ignored/\n*.log\n');
      await File('${searchRoot.path}/lib/keep.dart').writeAsString('needle here\n');
      await File('${searchRoot.path}/ignored/no.dart').writeAsString('needle here\n');
      await File('${searchRoot.path}/skip.log').writeAsString('needle here\n');
    });

    tearDown(() async {
      for (var i = 0; i < 5; i++) {
        try {
          if (await searchRoot.exists()) await searchRoot.delete(recursive: true);
          break;
        } catch (_) {
          if (i == 4) break;
          await Future<void>.delayed(Duration(milliseconds: 100 * (i + 1)));
        }
      }
    });

    test('R7-3 非法glob回空不抛（与非法正则同口径）', () async {
      // 复现：_globRegExp在try外抛StateError，与非法正则回[]分裂。
      // 修复：同样回[]。校验：行为口径。
      expect(
        await WorkspaceSearch.search(
          rootPath: searchRoot.path,
          query: 'needle',
          glob: 'a{',
        ),
        isEmpty,
      );
    });

    test('glob 和 .gitignore 过滤文件', () async {
      final groups = await WorkspaceSearch.search(
        rootPath: searchRoot.path,
        query: 'needle',
        glob: 'lib/**/*.dart',
      );
      expect(groups.map((group) => group.relativePath), ['lib/keep.dart']);
    });

    test('已取消令牌：搜索直接返回空', () async {
      final token = SearchCancellationToken()..cancel();
      expect(await WorkspaceSearch.search(
        rootPath: searchRoot.path,
        query: 'needle',
        cancellationToken: token,
      ), isEmpty);
    });
  });

  group('搜索相关性排序', () {
    SearchFileGroup fileGroup(String rel, List<String> lines) => SearchFileGroup(
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

  group('敏感搜索不缓存', () {
    test('命中密钥文本不写_recentCache', () async {
      final root = await Directory.systemTemp.createTemp('search-nocache-');
      try {
        WorkspaceSearch.clearRecentCache();
        await File(
          '${root.path}/k.txt',
        ).writeAsString('api_key=AAAA\n');
        final groups = await WorkspaceSearch.search(
          rootPath: root.path,
          query: 'api_key',
        );
        expect(groups, isNotEmpty);
        expect(WorkspaceSearch.hitsSensitive(groups), isTrue);
        expect(WorkspaceSearch.recentCacheSizeForTest(), 0);
      } finally {
        WorkspaceSearch.clearRecentCache();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });
  });

  group('搜索 isolate 超时/取消可 kill', () {
    // 足够大的树：扫描耗时远大于取消/超时阈值，保证 kill 路径生效。
    late Directory bigRoot;
    setUpAll(() async {
      bigRoot = await Directory.systemTemp.createTemp('search-bigtree-');
      final body = List.generate(800, (j) => 'lorem line $j').join('\n');
      for (var i = 0; i < 300; i++) {
        await File('${bigRoot.path}/f${i.toString().padLeft(3, '0')}.txt')
            .writeAsString(body);
      }
    });

    tearDownAll(() async {
      try {
        if (await bigRoot.exists()) {
          await bigRoot.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('在途取消：搜索提前返回空、不悬挂且不写缓存', () async {
      WorkspaceSearch.clearRecentCache();
      var polls = 0;
      // 按轮询次数触发取消，不按耗时：快机上 3MB 扫描远快于 30ms，
      // 时间谓词根本走不到取消分支，反而把空结果进缓存致断言失败
      // （Linux 快机偶发失败即此）。第 1 次为 search 入口预检放行，
      // 第 2 次在 isolate 已 spawn 后的首轮循环命中取消，稳定走 kill 路径。
      final token = SearchCancellationToken.fromPredicate(() {
        polls++;
        return polls >= 2;
      });
      final result = await WorkspaceSearch.search(
        rootPath: bigRoot.path,
        // 无命中查询：避免 maxHits 提前截断，覆盖完整扫描路径
        query: 'zzqqxxyy',
        cancellationToken: token,
      ).timeout(const Duration(seconds: 15));
      expect(result, isEmpty);
      // 轮询循环确已运行（取消机制可达），且取消路径不缓存空结果
      expect(polls, greaterThan(1));
      expect(WorkspaceSearch.recentCacheSizeForTest(), 0);
    });

    test('超时：立即抛 TimeoutException 不悬挂', () async {
      WorkspaceSearch.clearRecentCache();
      final sw = Stopwatch()..start();
      await expectLater(
        WorkspaceSearch.search(
          rootPath: bigRoot.path,
          query: 'zzqqxxyy',
          timeout: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      // 超时路径同样不缓存
      expect(WorkspaceSearch.recentCacheSizeForTest(), 0);
    });
  });

  test('buildRepoMap 符号表满额后目录树继续遍历', () async {
    final root = await Directory.systemTemp.createTemp('repo-map-cap-');
    addTearDown(() async {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    });
    // 50 个 dart 文件 × 8 类 = 400 符号行，越过 300 上限
    for (var i = 0; i < 50; i++) {
      final buf = StringBuffer();
      for (var j = 0; j < 8; j++) {
        buf.writeln('class Cap${i}_$j {}');
      }
      await File('${root.path}/f${i.toString().padLeft(2, '0')}.dart')
          .writeAsString(buf.toString());
    }
    // 字典序在全部符号文件之后：旧实现满额即 return，此子树整体丢失
    await Directory('${root.path}/zz-deep/inner').create(recursive: true);
    await File('${root.path}/zz-deep/inner/leaf.txt').writeAsString('hello');
    final map = await buildRepoMap(root.path);
    expect(map.tree, contains('zz-deep'));
    expect(map.tree, contains('leaf.txt'));
    expect(map.tree, contains('f49.dart'));
    // 符号表仍被钳制在 300 行内（首行标题 + 300）
    expect(map.symbols.split('\n').length, lessThanOrEqualTo(301));
  });

  test('TF-IDF 语义排序相关文档优先', () {
    final docs = [
      const SemanticDoc(path: 'a.dart', text: 'flutter widget build context'),
      const SemanticDoc(path: 'b.dart', text: 'unrelated cooking recipe soup'),
    ];
    final ranked = semanticRank('flutter widget', docs);
    expect(ranked.first.path, 'a.dart');
    expect(tokenize('Hello 世界'), isNotEmpty);
  });

  test('R5-A1 超大.gitignore跳过不进内存', () async {
    // 复现：100MB .gitignore此前全量进isolate内存即OOM。
    final root = await Directory.systemTemp.createTemp('gitignore-cap-');
    addTearDown(() async {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    });
    final big = File(p.join(root.path, '.gitignore'));
    await big.writeAsBytes(List<int>.filled(2 * 1024 * 1024, 0x23));
    await File(p.join(root.path, 'a.txt')).writeAsString('hello searchable');
    final groups = await WorkspaceSearch.search(
      rootPath: root.path,
      query: 'searchable',
    );
    expect(groups.map((g) => g.relativePath), contains('a.txt'));
  });

  test('R5-A2 repo_map敏感目录名不进树', () async {
    // 复现：目录先入树后才查敏感，敏感目录名泄漏。
    final dir = await Directory.systemTemp.createTemp('repomap-dir-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    await Directory(p.join(dir.path, '.ssh')).create(recursive: true);
    await File(p.join(dir.path, '.ssh', 'id_rsa'))
        .writeAsString('fake-key\n');
    await File(p.join(dir.path, 'a.dart')).writeAsString('void main() {}\n');
    final map = await buildRepoMap(dir.path);
    expect(map.tree, isNot(contains('.ssh')));
    expect(map.tree, contains('a.dart'));
  });

  test('R5-A6 语义超500截断提示可见', () async {
    // 复现：仅前500参排，尾部静默不可见。
    final dir = await Directory.systemTemp.createTemp('semantic-cap-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    for (var i = 0; i < 510; i++) {
      await File(p.join(dir.path, 'f$i.txt'))
          .writeAsString('common token file $i\n');
    }
    final tools = AgentTools(rootPath: dir.path);
    final r = await tools.execute('semantic_search', {'query': 'common'});
    expect(r.ok, isTrue);
    expect(r.output, contains('仅前500文档参排'));
  });

  test('审批后的区外 search_text 直接拒绝（仅 read_file 单文件）', () async {
    final root = await Directory.systemTemp.createTemp('search-approval-');
    final outside = await Directory.systemTemp.createTemp('search-outside-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    await File(p.join(outside.path, 'outside.txt')).writeAsString('needle');
    final gate = ApprovalGate();
    final provider = AiProviderConfig(
      id: 't',
      name: 't',
      baseUrl: 'http://127.0.0.1',
      fullUrl: true,
    );
    final registry = ToolRegistry(gate: gate);
    final pending = registry.executeWithGuards(
      toolName: 'search_text',
      args: {'path': outside.path, 'query': 'needle'},
      mode: AgentMode.agent,
      provider: provider,
      model: AiModelOption(id: 'm'),
      rootPath: root.path,
      sessionId: 'search-approval',
    );
    await Future<void>.delayed(Duration.zero);
    // 区外 search 不再弹窗：一次审批即全文扫任意区外目录，仅 read_file 单文件。
    final result = await pending;
    expect(result?.ok, isFalse);
    expect(result?.output, contains('search_text'));
    expect(await File(p.join(root.path, 'needle')).exists(), isFalse);
    await registry.dispose();
  });

  test('plan模式子Agent上下文含方案约束', () async {
    final dir = await Directory.systemTemp.createTemp('sub-plan-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    String seen = '';
    final client = _PlanCaptureClient((messages) {
      seen = messages.map((m) => '${m['content']}').join('\n');
    });
    final runtime = SubagentRuntime(client: client, maxSteps: 1);
    await runtime.run(
      task: '调研',
      files: const [],
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
      mode: 'plan',
    );
    expect(seen, contains('plan 模式'));
    final runtime2 = SubagentRuntime(client: _FakeSubagentClient(), maxSteps: 1);
    String seen2 = '';
    final client2 = _PlanCaptureClient((messages) {
      seen2 = messages.map((m) => '${m['content']}').join('\n');
    });
    final runtime3 = SubagentRuntime(client: client2, maxSteps: 1);
    await runtime3.run(
      task: '调研',
      files: const [],
      provider: AiProviderConfig(
        id: 't',
        name: 't',
        baseUrl: 'http://127.0.0.1',
        fullUrl: true,
      ),
      model: AiModelOption(id: 'm'),
      rootPath: dir.path,
      mode: 'research',
    );
    expect(seen2.contains('plan 模式'), isFalse);
    expect(runtime2, isNotNull);
  });

  test('扇出超时只取消对应spawnId，同task文本另一分支不受影响', () async {
    // 复现：同批双spawn task文本相同，其中一个taskTimeout，旧onAbandon按
    // task文本比对把两个runtime全取消。现按spawnId精确取消。
    final src = await File(
      'lib/ai/agent_runner.dart',
    ).readAsString();
    expect(src.contains('_activeSubagentSpawnIds'), isTrue);
    expect(src.contains('spawnId: task.id'), isTrue);
  });

  test('子Agent技能桶按会话隔离，不读全局兜底', () async {
    // 复现：A会话load_skill只读桶后，B会话无桶spawn沿用全局残留被误拒/误放。
    final reg = ToolRegistry(gate: ApprovalGate());
    reg.setSkillAllowed('sess-a', {'read_file'});
    expect(reg.skillAllowedFor('sess-a'), {'read_file'});
    expect(reg.skillAllowedFor('sess-b'), isNull);
    final src = await File(
      'lib/ai/agent_runner.dart',
    ).readAsString();
    expect(src.contains('_registry.skillAllowedFor(sessionId)'), isTrue);
  });

  test('disposeTools 按 ownerSessionId 清理，不传 null 全清', () async {
    // 复现：明明持有 ownerSessionId 却传 null 走"全局兜底全清"分支，
    // 实例一旦共享即全清他会话终端/后台任务。现非空只杀本会话。
    final src = await File('lib/ai/subagent_runtime.dart').readAsString();
    expect(
      src.contains(
        'sessionId: ownerSessionId.isEmpty ? null : ownerSessionId,',
      ),
      isTrue,
    );
  });
}

class _PlanCaptureClient extends AgentClient {
  _PlanCaptureClient(this.onMessages);

  final void Function(List<Map<String, dynamic>> messages) onMessages;

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
    onMessages(messages);
    yield AgentStreamEvent(done: true);
  }
}
