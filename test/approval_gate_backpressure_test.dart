import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/approval_gate.dart';
import 'package:my_ide/ai/provider_config.dart';
import 'package:my_ide/ai/tool_registry.dart';

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

/// S1-12：审批队列背压可区分——队列满时 askApproval 返回 false 并置
/// _backpressuredSessions 标记，下游凭 takeBackpressured 消费，
/// 不再与"用户拒绝/取消"混同。
void main() {
  group('审批队列背压', () {
    test('队列塞满后 askApproval 立即 false 且置背压标记：消费即摘除', () async {
      final gate = ApprovalGate();
      final futures = <Future<bool>>[];
      try {
        // 塞满单会话桶（maxQueueLength=64）：首个成为 pending，其余排队。
        for (var i = 0; i < ApprovalGate.maxQueueLength; i++) {
          futures.add(
            gate.askApproval(
              PendingApproval(kind: 'file', title: 't$i', detail: 'd$i'),
              sessionId: 's-bp',
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(gate.pendingApproval?.title, 't0',
            reason: '队首应已展示，其余 63 项排队');
        // 第 65 个：背压立即 false（不排队、不弹窗）。
        final overflow = await gate.askApproval(
          PendingApproval(kind: 'file', title: 'overflow', detail: 'overflow'),
          sessionId: 's-bp',
        );
        expect(overflow, isFalse);
        // 背压标记置位且消费即摘除：true → false。
        expect(gate.takeBackpressured('s-bp'), isTrue);
        expect(gate.takeBackpressured('s-bp'), isFalse);
        expect(gate.takeApprovalTimeout('s-bp'), isFalse,
            reason: '背压不是超时，两个标记互不串扰');
      } finally {
        // 结算全部在途审批，避免 pending Timer 泄漏进下一用例。
        gate.endRun(sessionId: 's-bp');
        for (final f in futures) {
          try {
            await f;
          } catch (_) {}
        }
        gate.dispose();
      }
    });

    test('用户拒绝不置背压标记：正常决议与背压可区分', () async {
      final gate = ApprovalGate();
      try {
        final denied = gate.askApproval(
          PendingApproval(kind: 'file', title: 'd', detail: 'd'),
          sessionId: 's-deny',
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        gate.resolveApproval(false);
        expect(await denied, isFalse);
        expect(gate.takeBackpressured('s-deny'), isFalse,
            reason: '拒绝走正常决议，不置背压标记');
      } finally {
        gate.dispose();
      }
    });

    test('背压标记随轮起清理：beginRun 后不残留误判下次拒绝', () async {
      final gate = ApprovalGate();
      final futures = <Future<bool>>[];
      try {
        for (var i = 0; i < ApprovalGate.maxQueueLength; i++) {
          futures.add(
            gate.askApproval(
              PendingApproval(kind: 'file', title: 't$i', detail: 'd$i'),
              sessionId: 's-clean',
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(
          await gate.askApproval(
            PendingApproval(kind: 'file', title: 'x', detail: 'x'),
            sessionId: 's-clean',
          ),
          isFalse,
        );
        expect(gate.takeBackpressured('s-clean'), isTrue);
        // 模拟旧轮队列满打标后未消费，新轮 beginRun 摘残留。
        for (var i = 0; i < ApprovalGate.maxQueueLength; i++) {
          gate.resolveApproval(true);
        }
        for (final f in futures) {
          try {
            await f;
          } catch (_) {}
        }
        gate.beginRun(sessionId: 's-clean');
        expect(gate.takeBackpressured('s-clean'), isFalse,
            reason: '旧轮背压标记不得把新轮拒绝误判为队列满');
      } finally {
        gate.endRun(sessionId: 's-clean');
        gate.dispose();
      }
    });

    test('ToolRegistry 写通道背压回填"未送审"占位，不冒充用户拒绝', () async {
      // 端到端：塞满队列后走 executeWithGuards 写路径（ask 档），
      // shouldProceed 因背压 false → registry 回填占位说明。
      final gate = ApprovalGate();
      final root = await Directory.systemTemp.createTemp('bp-write-');
      final reg = ToolRegistry(gate: gate)
        ..approveCreateInside = ApprovalAction.ask;
      final futures = <Future<bool>>[];
      try {
        for (var i = 0; i < ApprovalGate.maxQueueLength; i++) {
          futures.add(
            gate.askApproval(
              PendingApproval(kind: 'file', title: 't$i', detail: 'd$i'),
              sessionId: 's-reg',
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final r = await reg.executeWithGuards(
          toolName: 'write_file',
          args: {'path': 'a.txt', 'content': 'hi'},
          mode: AgentMode.agent,
          provider: AiProviderConfig(
            id: 't',
            name: 't',
            baseUrl: 'http://127.0.0.1',
            fullUrl: true,
          ),
          model: AiModelOption(id: 'm'),
          rootPath: root.path,
          sessionId: 's-reg',
        );
        expect(r?.ok, isFalse);
        expect(r?.output, contains('审批队列已满，本次未送审'));
        expect(r?.output, contains('a.txt'));
        // 未落盘：背压路径不得静默执行写入。
        expect(File('${root.path}/a.txt').existsSync(), isFalse);
        expect(gate.takeBackpressured('s-reg'), isFalse,
            reason: '占位回填即消费背压标记：registry 已摘除，不再残留');
      } finally {
        gate.endRun(sessionId: 's-reg');
        for (final f in futures) {
          try {
            await f;
          } catch (_) {}
        }
        await reg.dispose();
        gate.dispose();
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('registry 两侧消费点均接 takeBackpressured（源码口径）', () {
      // 区外/敏感读通道与写通道的审批消费点都需区分背压。
      final src = readLibSource('ai/tool_registry.dart');
      expect(src.contains('takeBackpressured'), isTrue);
      expect(src.contains('审批队列已满，本次未送审'), isTrue);
      expect(src.contains('takeApprovalTimeout'), isTrue,
          reason: '超时占位口径保留不弱化');
    });
  });
}
