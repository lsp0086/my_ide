import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/workspace/workspace_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  group('S6: 对话断点日志崩溃恢复', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('chat-journal-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('崩溃遗留的 journal 被恢复为一条中断消息并清除日志', () async {
      final store = ChatStore();
      await store.loadForProject(root.path);
      await store.newChat();
      final sessionId = store.active!.id;
      store.dispose();

      // 模拟进行中的一轮：写了断点日志后进程被杀死（未 clear）。
      final journalWriter = ChatStore();
      await journalWriter.loadForProject(root.path);
      await journalWriter.writeTurnJournal(
        sessionId: sessionId,
        text: 'partial answer body',
        files: const ['lib/a.dart'],
        thinking: 'some thoughts',
      );
      journalWriter.dispose();

      // 重启加载。
      final recovered = ChatStore();
      await recovered.loadForProject(root.path);
      final session = recovered.sessionById(sessionId);
      expect(session, isNotNull);
      expect(session!.messages, hasLength(1));
      final msg = session.messages.single;
      expect(msg.role, 'assistant');
      expect(msg.text, contains('partial answer body'));
      expect(msg.text, contains('中断'));
      expect(msg.files, contains('lib/a.dart'));
      expect(msg.stopReason, '中断恢复');
      expect(msg.thinking, 'some thoughts');

      // journal 已被清除，不会二次恢复。
      expect(
        await File(
          p.join(root.path, '.my_ide', 'chats', '$sessionId.journal'),
        ).exists(),
        isFalse,
      );
      recovered.dispose();
    });

    test('正常结束 clearTurnJournal 后重启不产生恢复消息', () async {
      final store = ChatStore();
      await store.loadForProject(root.path);
      await store.newChat();
      final sessionId = store.active!.id;
      await store.writeTurnJournal(sessionId: sessionId, text: 'wip');
      await store.clearTurnJournal(sessionId);
      store.dispose();

      final recovered = ChatStore();
      await recovered.loadForProject(root.path);
      final session = recovered.sessionById(sessionId);
      expect(session, isNotNull);
      expect(session!.messages, isEmpty);
      recovered.dispose();
    });
  });

  group('W4: 自动保存跳过冲突文件', () {
    late Directory root;
    late WorkspaceController controller;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('autosave-');
      controller = WorkspaceController();
    });

    tearDown(() async {
      controller.dispose();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('脏 tab 自动落盘，冲突 tab 跳过', () async {
      final clean = File(p.join(root.path, 'clean.txt'));
      final conflicted = File(p.join(root.path, 'conflicted.txt'));
      await clean.writeAsString('a');
      await conflicted.writeAsString('b');

      var cleanSaves = 0;
      var conflictSaves = 0;
      controller.openFile(clean.path);
      controller.openFile(conflicted.path);

      controller.registerSaveHandler(clean.path, () async {
        cleanSaves++;
        controller.setDirty(clean.path, false);
        return true;
      });
      controller.registerSaveHandler(conflicted.path, () async {
        conflictSaves++;
        controller.setDirty(conflicted.path, false);
        return true;
      });

      controller.setDirty(clean.path, true);
      controller.setDirty(conflicted.path, true);
      controller.markConflict(conflicted.path);

      final saved = await controller.autosaveDirtyTabs();
      expect(saved, [clean.path]);
      expect(cleanSaves, 1);
      expect(conflictSaves, 0, reason: '冲突文件必须留给用户抉择');
    });

    test('干净 tab 不触发保存', () async {
      final file = File(p.join(root.path, 'plain.txt'));
      await file.writeAsString('x');
      var saves = 0;
      controller.openFile(file.path);
      controller.registerSaveHandler(file.path, () async {
        saves++;
        return true;
      });
      final saved = await controller.autosaveDirtyTabs();
      expect(saved, isEmpty);
      expect(saves, 0);
    });

    test('S4: 保留本地后待覆盖确认，自动保存跳过', () async {
      final file = File(p.join(root.path, 'keep.txt'));
      await file.writeAsString('disk v1');
      controller.openFile(file.path);
      expect(controller.needsOverwriteConfirm(file.path), isFalse);

      await controller.resolveConflict(file.path, keepLocal: true);
      expect(controller.needsOverwriteConfirm(file.path), isTrue);

      // 自动保存不能弹框：跳过待确认文件。
      var saves = 0;
      controller.registerSaveHandler(file.path, () async {
        saves++;
        return true;
      });
      controller.setDirty(file.path, true);
      final saved = await controller.autosaveDirtyTabs();
      expect(saved, isEmpty);
      expect(saves, 0);

      controller.clearOverwriteConfirm(file.path);
      expect(controller.needsOverwriteConfirm(file.path), isFalse);
    });

    test('S5: 卸载暂存的草稿可取回，且一次性消费', () async {
      controller.stashDraft('/tmp/a.txt', 'unsaved buffer');
      expect(controller.takeDraft('/tmp/a.txt'), 'unsaved buffer');
      expect(controller.takeDraft('/tmp/a.txt'), isNull);
    });

    test('S2: 磁盘在加载后被外部改写出可检测', () async {
      final file = File(p.join(root.path, 'watch.txt'));
      await file.writeAsString('v1');
      controller.openFile(file.path);
      expect(controller.diskChangedSinceStamp(file.path), isFalse);

      // 模拟外部（Agent/其它进程）改写并把 mtime 推到未来，避开低分辨率时间戳。
      await file.writeAsString('v2 external');
      await file.setLastModified(DateTime.now().add(const Duration(seconds: 5)));
      expect(controller.diskChangedSinceStamp(file.path), isTrue);

      // 冲突抉择/保存后重新戳记，恢复一致。
      controller.rememberDiskStamp(file.path);
      expect(controller.diskChangedSinceStamp(file.path), isFalse);
    });
  });

  group('P5: AGENTS.md 项目规则加载', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('rules-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('无规则文件时返回空', () async {
      expect(await loadProjectRules(root.path), isEmpty);
      expect(await loadProjectRules(null), isEmpty);
    });

    test('读取工作区根目录 AGENTS.md 并截断超长内容', () async {
      await File(p.join(root.path, 'AGENTS.md'))
          .writeAsString('对话期间禁止新建文件，优先编辑已有文件。');
      final rules = await loadProjectRules(root.path);
      expect(rules, contains('禁止新建文件'));

      // 超长规则截断保护。
      await File(p.join(root.path, 'AGENTS.md'))
          .writeAsString('x' * 9000);
      final truncated = await loadProjectRules(root.path);
      expect(truncated.length, lessThan(8300));
      expect(truncated, contains('已截断'));
    });
  });
}
