import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
String readLibSource(String relPath) {
  var out = File('lib/$relPath').readAsStringSync();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = File('lib/$relPath')
      .parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += f.readAsStringSync();
  }
  return out;
}

void main() {
  group('会话落盘与分叉完整性', () {
    late Directory rootA;
    late Directory rootB;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      rootA = await Directory.systemTemp.createTemp('chat-integ-a-');
      rootB = await Directory.systemTemp.createTemp('chat-integ-b-');
    });

    tearDown(() async {
      for (final d in [rootA, rootB]) {
        try {
          if (await d.exists()) await d.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('恢复中途切项目：旧会话恢复不写入新项目目录', () async {
      final store = ChatStore();
      await store.loadForProject(rootA.path);
      await store.newChat();
      final sessionId = store.active!.id;
      await store.writeTurnJournal(
        sessionId: sessionId,
        text: 'partial answer body',
      );
      store.dispose();

      // 重启加载到一半时切项目：新目录下不应出现旧会话的恢复写入。
      final recovered = ChatStore();
      await recovered.loadForProject(rootA.path);
      await recovered.loadForProject(rootB.path);
      final leaked = File(
        p.join(rootB.path, '.my_ide', 'chats', '$sessionId.json'),
      );
      expect(await leaked.exists(), isFalse);
      recovered.dispose();
    });

    test('带图分叉后删源会话：新引用仍可解析', () async {
      final store = ChatStore();
      await store.loadForProject(rootA.path);
      await store.newChat();
      final srcId = store.active!.id;
      // 落一张真图资产（最小合法 PNG 魔数负载）。
      final bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1];
      final ref = await store.saveChatImageAsset(
        sessionId: srcId,
        bytes: bytes,
        mime: 'image/png',
      );
      await store.addMessageTo(
        sessionId: srcId,
        msg: ChatMessage(role: 'user', text: '看图', images: [ref]),
      );
      final untilId = store.sessionById(srcId)!.messages.single.id;
      final forkId = await store.forkSession(srcId, untilId);
      expect(forkId, isNotNull);
      final forkRef =
          store.sessionById(forkId!)!.messages.single.images.single;
      expect(forkRef.startsWith('asset:chat_assets/$forkId/'), isTrue);
      await store.deleteChat(srcId);
      // 源目录已删，分支引用仍可读出 dataUrl。
      final resolved = await store.resolveChatImage(forkRef);
      expect(resolved, isNotNull);
      expect(resolved, startsWith('data:image/png;base64,'));
      store.dispose();
    });

    test('分叉继承压缩水位：摘要与 until 同步传递', () async {
      final store = ChatStore();
      await store.loadForProject(rootA.path);
      await store.newChat();
      final srcId = store.active!.id;
      await store.addMessageTo(
        sessionId: srcId,
        msg: ChatMessage(role: 'user', text: '第一问'),
      );
      await store.addMessageTo(
        sessionId: srcId,
        msg: ChatMessage(role: 'assistant', text: '第一答'),
      );
      final src = store.sessionById(srcId)!;
      await store.saveCompaction(
        sessionId: srcId,
        summary: '旧摘要',
        droppedCount: 1,
        untilMessageId: src.messages.first.id,
      );
      final forkId = await store.forkSession(srcId, src.messages.last.id);
      expect(forkId, isNotNull);
      final fork = store.sessionById(forkId!)!;
      expect(fork.compactionSummary, '旧摘要');
      expect(
        fork.compactionUntilMessageId,
        src.compactionUntilMessageId,
      );
      store.dispose();
    });
  });

  group('truncateConversation 数据面', () {
    late Directory root;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      root = await Directory.systemTemp.createTemp('truncate-');
    });

    tearDown(() async {
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    });

    /// 建一个含 [count] 条消息的会话，返回 store 与会话 id。
    Future<(ChatStore, String)> seededStore(int count) async {
      final store = ChatStore();
      await store.loadForProject(root.path);
      await store.newChat();
      final sid = store.active!.id;
      for (var i = 0; i < count; i++) {
        await store.addMessageTo(
          sessionId: sid,
          msg: ChatMessage(
            role: i.isEven ? 'user' : 'assistant',
            text: '消息$i',
            // 带文件与版本引用：截断不得改写保留消息的元数据。
            files: i.isEven ? const [] : ['lib/gen_$i.dart'],
            afterVersionId: i.isEven ? null : 'v$i',
          ),
        );
      }
      return (store, sid);
    }

    test('截断后 messages 边界=切点，保留消息元数据不动', () async {
      // 复现：此前无"仅截断对话"语义，换提示词重试只能整轮回退，
      // 已写代码被一并撤销。
      final (store, sid) = await seededStore(5);
      final before = store.sessionById(sid)!;
      final cut = before.messages[2];

      final ok = await store.truncateConversation(
        sessionId: sid,
        untilMessageId: cut.id,
      );
      expect(ok, isTrue);

      final after = store.sessionById(sid)!;
      expect(after.messages.length, 3);
      expect(after.messages.last.id, cut.id);
      // 保留区间逐条原位（id 序列一致）。
      for (var i = 0; i < 3; i++) {
        expect(after.messages[i].id, before.messages[i].id);
      }
      // 保留消息的文件/版本引用不被截断改写（文件语义与对话解耦）。
      expect(after.messages[1].files, ['lib/gen_1.dart']);
      expect(after.messages[1].afterVersionId, 'v1');
      // 切点自身（user 消息）原样保留。
      expect(after.messages[2].role, 'user');
      expect(after.messages[2].files, isEmpty);
      store.dispose();
    });

    test('截断不触碰文件树：工作区文件逐字节不变', () async {
      // 校验标准中的"文件树未动"：截断只删对话，不得回写任何工作区文件。
      final target = File(p.join(root.path, 'gen.dart'));
      const payload = '// agent written\nvoid main() {}\n';
      await target.writeAsString(payload, flush: true);
      final before = await target.readAsBytes();

      final (store, sid) = await seededStore(4);
      final ok = await store.truncateConversation(
        sessionId: sid,
        untilMessageId: store.sessionById(sid)!.messages[1].id,
      );
      expect(ok, isTrue);

      expect(await target.readAsBytes(), before);
      expect(await target.readAsString(), payload);
      store.dispose();
    });

    test('截断到最后一条：无消息可删仍返回 true', () async {
      final (store, sid) = await seededStore(3);
      final last = store.sessionById(sid)!.messages.last;
      final ok = await store.truncateConversation(
        sessionId: sid,
        untilMessageId: last.id,
      );
      expect(ok, isTrue);
      expect(store.sessionById(sid)!.messages.length, 3);
      store.dispose();
    });

    test('无效入参返回 false：会话不存在 / 消息 id 不存在', () async {
      final (store, sid) = await seededStore(3);
      expect(
        await store.truncateConversation(
          sessionId: 'no-such-session',
          untilMessageId: 'x',
        ),
        isFalse,
      );
      expect(
        await store.truncateConversation(
          sessionId: sid,
          untilMessageId: 'no-such-message',
        ),
        isFalse,
      );
      // 失败不得改动消息。
      expect(store.sessionById(sid)!.messages.length, 3);
      store.dispose();
    });

    test('运行锁定拒绝截断，解锁后可截断（与 forkSession 同口径）', () async {
      final (store, sid) = await seededStore(4);
      final cut = store.sessionById(sid)!.messages[1];
      store.lockSession(sid);
      expect(
        await store.truncateConversation(
          sessionId: sid,
          untilMessageId: cut.id,
        ),
        isFalse,
      );
      expect(store.sessionById(sid)!.messages.length, 4);
      store.unlockSession(sid);
      expect(
        await store.truncateConversation(
          sessionId: sid,
          untilMessageId: cut.id,
        ),
        isTrue,
      );
      expect(store.sessionById(sid)!.messages.length, 2);
      store.dispose();
    });

    test('摘要边界同步同灭：截断点早于摘要 until → 三字段清空', () async {
      final (store, sid) = await seededStore(4);
      final s = store.sessionById(sid)!;
      await store.saveCompaction(
        sessionId: sid,
        summary: '旧摘要',
        droppedCount: 2,
        untilMessageId: s.messages[1].id,
      );
      expect(s.compactionSummary, '旧摘要');
      expect(s.compactionUntilMessageId, s.messages[1].id);
      expect(s.compactedAt, isNotNull);

      // 截到摘要覆盖区间之前：残留摘要描述的是已删历史 → 必须同灭。
      final ok = await store.truncateConversation(
        sessionId: sid,
        untilMessageId: s.messages[0].id,
      );
      expect(ok, isTrue);
      expect(s.compactionSummary, isNull);
      expect(s.compactionUntilMessageId, isNull);
      expect(s.compactedAt, isNull);
      expect(s.messages.length, 1);
      store.dispose();
    });

    test('摘要边界同步同灭：截断点不早于摘要 until → 三字段保留', () async {
      final (store, sid) = await seededStore(4);
      final s = store.sessionById(sid)!;
      await store.saveCompaction(
        sessionId: sid,
        summary: '旧摘要',
        droppedCount: 2,
        untilMessageId: s.messages[1].id,
      );

      // 切点恰为 until 所在消息：摘要覆盖区间完整保留。
      final okAtUntil = await store.truncateConversation(
        sessionId: sid,
        untilMessageId: s.messages[1].id,
      );
      expect(okAtUntil, isTrue);
      expect(s.compactionSummary, '旧摘要');
      expect(s.compactionUntilMessageId, s.messages[1].id);
      expect(s.compactedAt, isNotNull);
      expect(s.messages.length, 2);
      store.dispose();
    });

    test('E2E：截断后续跑不引用旧消息（重载 ChatStore 现读）', () async {
      // 复现路径：AgentRunner 每轮从 session.messages 现读历史；
      // 截断落盘后重载，读到的新历史不得含被删消息文本。
      final (store, sid) = await seededStore(4);
      final cut = store.sessionById(sid)!.messages[1];
      expect(
        await store.truncateConversation(
          sessionId: sid,
          untilMessageId: cut.id,
        ),
        isTrue,
      );
      store.dispose();

      final reloaded = ChatStore();
      await reloaded.loadForProject(root.path);
      final session = reloaded.sessionById(sid);
      expect(session, isNotNull);
      expect(session!.messages.length, 2);
      expect(session.messages.last.id, cut.id);
      // 被删消息文本不出现在重载后的历史里（Runner 无从引用）。
      final texts = session.messages.map((m) => m.text).toList();
      expect(texts, ['消息0', '消息1']);
      expect(texts.contains('消息2'), isFalse);
      expect(texts.contains('消息3'), isFalse);
      reloaded.dispose();
    });

    test('truncateConversation 实现口径：锁守卫+清尾+摘要同灭+走 _save，无版本操作', () async {
      final src = readLibSource('ai/chat_store.dart');
      final start = src.indexOf('Future<bool> truncateConversation({');
      expect(start, greaterThan(0));
      // 库拆分后 truncateConversation 与 saveCompaction 分属不同 part，
      // 切片终点改为 truncateConversation 之后紧邻的 removeFileFromMessage
      // doc 锚点，避免切片越界吞入其它方法的实现体。
      final end = src.indexOf('/// 单文件/单块回退后', start);
      expect(end, greaterThan(start));
      final body = src.substring(start, end);
      // 运行锁守卫（与 forkSession 同口径）。
      expect(
        body.contains('if (_lockedSessions.contains(sessionId)) return false;'),
        isTrue,
      );
      // 保留 [0, cut]（含），删除其后全部消息。
      expect(
        body.contains(
          'session.messages.removeRange(cut + 1, session.messages.length)',
        ),
        isTrue,
      );
      // 摘要边界同步同灭：三字段成组清空。
      expect(body.contains('session.compactionSummary = null;'), isTrue);
      expect(body.contains('session.compactionUntilMessageId = null;'), isTrue);
      expect(body.contains('session.compactedAt = null;'), isTrue);
      // 落盘走现有 _save（陈旧守卫与写链都在其内）。
      expect(body.contains('await _save(session);'), isTrue);
      // 不触碰任何版本/checkpoint 操作（仅截断对话语义）。
      expect(body.contains('revertDropVersions'), isFalse);
      expect(body.contains('revertSingleFile'), isFalse);
      expect(body.contains('removeFileFromMessage'), isFalse);
      expect(body.contains('.checkpoint('), isFalse);
    });
  });
}
