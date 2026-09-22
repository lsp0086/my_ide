import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_runner.dart';
import 'package:my_ide/ai/approval_gate.dart';

void main() {
  test('T1 审批队列串行推进：resolve 队首后自动弹下一项', () async {
    final gate = ApprovalGate();
    final first = gate.askApproval(
      PendingApproval(kind: 'file', title: 'first', detail: 'first'),
    );
    final second = gate.askApproval(
      PendingApproval(kind: 'file', title: 'second', detail: 'second'),
    );
    expect(gate.pendingApproval?.title, 'first');
    gate.resolveApproval(true);
    expect(await first, isTrue);
    expect(gate.pendingApproval?.title, 'second');
    gate.resolveApproval(false);
    expect(await second, isFalse);
  });

  test('T1 提问队列串行推进：resolve 队首后自动弹下一项', () async {
    final gate = ApprovalGate();
    final first = gate.askUser(
      AgentQuestion(question: 'q1', options: const ['a']),
    );
    final second = gate.askUser(
      AgentQuestion(question: 'q2', options: const ['b']),
    );
    expect(gate.pendingQuestion?.question, 'q1');
    gate.resolveQuestion('a');
    expect(await first, 'a');
    expect(gate.pendingQuestion?.question, 'q2');
    gate.resolveQuestion(null);
    expect(await second, isNull);
  });
}
