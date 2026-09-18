import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/ai/context_compactor.dart';

ChatMessage msg(String id, String text) =>
    ChatMessage(id: id, role: 'user', text: text);

void main() {
  test('首次压缩切掉最近窗口之前的全部消息', () {
    final history = [
      for (var i = 1; i <= 12; i++) msg('$i', '约束$i'),
    ];
    final sliced = ContextCompactor.sliceForCompaction(
      history: history,
      keepRecent: 8,
    );
    expect(sliced.toSummarize.map((e) => e.id), ['1', '2', '3', '4']);
    expect(sliced.kept.map((e) => e.id), ['5', '6', '7', '8', '9', '10', '11', '12']);
    expect(sliced.droppedCount, 4);
  });

  test('二次滚动只摘要旧边界之后、最近窗口之前的消息', () {
    final history = [
      for (var i = 1; i <= 16; i++) msg('$i', '约束$i 禁止回退方案A'),
    ];
    final sliced = ContextCompactor.sliceForCompaction(
      history: history,
      keepRecent: 8,
      previousUntilMessageId: '4',
    );
    expect(sliced.toSummarize.map((e) => e.id), ['5', '6', '7', '8']);
    expect(sliced.kept.map((e) => e.id).first, '9');
    expect(sliced.toSummarize.any((e) => e.text.contains('禁止回退方案A')), isTrue);
  });

  test('三次滚动继续只吃尚未摘要的中间段', () {
    final history = [
      for (var i = 1; i <= 20; i++) msg('$i', '目标继续，约束$i'),
    ];
    final sliced = ContextCompactor.sliceForCompaction(
      history: history,
      keepRecent: 8,
      previousUntilMessageId: '8',
    );
    expect(sliced.toSummarize.map((e) => e.id), ['9', '10', '11', '12']);
    expect(sliced.kept.map((e) => e.id), ['13', '14', '15', '16', '17', '18', '19', '20']);
  });

  test('旧边界找不到时不丢已有覆盖范围，整段中间历史进入待摘要', () {
    final history = [
      for (var i = 10; i <= 20; i++) msg('$i', 'msg$i'),
    ];
    final sliced = ContextCompactor.sliceForCompaction(
      history: history,
      keepRecent: 4,
      previousUntilMessageId: 'missing',
    );
    expect(sliced.toSummarize.map((e) => e.id), ['10', '11', '12', '13', '14', '15', '16']);
    expect(sliced.kept.length, 4);
  });
}
