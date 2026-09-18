import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/responses_delta.dart';

void main() {
  test('无 previous id 时发送完整本地历史', () {
    final messages = [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'u1'},
      {'role': 'assistant', 'content': 'a1'},
      {'role': 'user', 'content': 'u2'},
    ];
    expect(
      ResponsesDelta.incrementalInput(
        messages: messages,
        previousResponseId: null,
        sentUntil: 0,
      ),
      messages,
    );
  });

  test('跨轮续聊只发 system 和本轮新 user', () {
    final messages = [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'u1'},
      {'role': 'assistant', 'content': 'a1'},
      {'role': 'user', 'content': 'u2'},
    ];
    final delta = ResponsesDelta.incrementalInput(
      messages: messages,
      previousResponseId: 'resp_1',
      sentUntil: 0,
    );
    expect(delta.map((e) => e['content']), ['sys', 'u2']);
  });

  test('工具循环只发尚未发送的增量，每条 user/tool 只出现一次', () {
    final messages = [
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': 'u1'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call_1',
            'type': 'function',
            'function': {'name': 'read_file', 'arguments': '{}'},
          },
        ],
      },
      {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'name': 'read_file',
        'content': 'ok',
      },
    ];
    final delta = ResponsesDelta.incrementalInput(
      messages: messages,
      previousResponseId: 'resp_2',
      sentUntil: 3,
    );
    expect(delta, hasLength(1));
    expect(delta.single['role'], 'tool');
    expect(delta.single['tool_call_id'], 'call_1');
  });

  test('游标已到末尾则不再发 input', () {
    final messages = [
      {'role': 'user', 'content': 'u1'},
    ];
    expect(
      ResponsesDelta.incrementalInput(
        messages: messages,
        previousResponseId: 'resp_1',
        sentUntil: 1,
      ),
      isEmpty,
    );
  });
}
