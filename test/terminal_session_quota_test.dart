import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/command_process_manager.dart';
import 'package:my_ide/ai/terminal_session.dart';

void main() {
  group('终端配额与退出回收', () {
    late Directory workspace;
    late CommandProcessManager manager;

    setUp(() async {
      workspace = await Directory.systemTemp.createTemp('terminal-quota-');
      manager = CommandProcessManager();
    });

    tearDown(() async {
      await manager.dispose();
      try {
        if (await workspace.exists()) {
          await workspace.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('并发创建恰 8 成功：第 9 起拒绝且不建进程', () async {
      if (Platform.isWindows) return;
      final store = TerminalSessionStore(manager);
      addTearDown(() async {
        for (final id in store.sessions.keys.toList()) {
          final s = store.sessions[id];
          if (s != null) {
            await store.kill(id, ownerSessionId: s.ownerSessionId);
          }
        }
      });
      final results = await Future.wait(
        List.generate(
          20,
          (_) async {
            try {
              await store.create(
                rootPath: workspace.path,
                ownerSessionId: 'quota-owner',
              );
              return true;
            } catch (_) {
              return false;
            }
          },
        ),
        eagerError: false,
      );
      expect(results.where((e) => e).length, 8);
      expect(store.sessions.length, 8);
      expect(manager.activeCount, 8);
    });

    test('自然退出后名额回收：可再建且不泄漏', () async {
      if (Platform.isWindows) return;
      final store = TerminalSessionStore(manager);
      final before = TerminalSessionStore.globalLiveCountForTest();
      // 走 Store 真实路径：create 建常驻 shell，stdin exit 使其自然退出，
      // exitCode 回调经 onNaturalExit 摘表+回补名额（S2-6）。
      final session = await store.create(
        rootPath: workspace.path,
        ownerSessionId: 'quota-owner',
      );
      expect(TerminalSessionStore.globalLiveCountForTest(), before + 1);
      await session.writeStdin('exit');
      var reaped = false;
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (!store.sessions.containsKey(session.id) &&
            TerminalSessionStore.globalLiveCountForTest() == before) {
          reaped = true;
          break;
        }
      }
      expect(reaped, isTrue, reason: '自然退出必须摘表并回补名额');
      // 名额已回收：可再建且计数只 +1，不泄漏。
      final created = await store.create(
        rootPath: workspace.path,
        ownerSessionId: 'quota-owner',
      );
      addTearDown(() async {
        await store.kill(created.id, ownerSessionId: 'quota-owner');
      });
      expect(store.sessions.containsKey(created.id), isTrue);
      expect(
        TerminalSessionStore.globalLiveCountForTest(),
        before + 1,
      );
    });
  });
}
