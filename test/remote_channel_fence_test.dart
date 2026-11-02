import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/remote_channel.dart';

/// S3-7 出站分片代码围栏配对回归：
/// ① 围栏内不因标题/容量主动断段；
/// ② 围栏内超限断段时，当前片补闭合 ```、下片以原开头行（含语言标注）
///    重开围栏，保证每片内 ``` 计数为偶数；
/// ③ 不破坏既有分片上限/中文 rune 语义（无围栏参与时拼接还原原文）。
void main() {
  int fenceCount(String part) => '```'.allMatches(part).length;

  test('围栏+超长文本：每片围栏配对（偶数）', () {
    final code = List.generate(
      100,
      (i) => 'print("line $i 中文内容输出测试");',
    ).join('\n');
    final text = '# 标题\n前言文字。\n```dart\n$code\n```\n结尾。';
    expect(text.runes.length, greaterThan(2000));
    final parts = RemoteCommands.splitOutbound(text);
    expect(parts.length, greaterThan(1));
    for (final part in parts) {
      expect(fenceCount(part) % 2, 0,
          reason: '每片 ``` 计数须为偶数（配对）:\n$part');
    }
    // 围栏内行不被拦腰断开：末行完整出现在某一片中。
    expect(
      parts.any((p) => p.contains('print("line 99 中文内容输出测试");')),
      isTrue,
    );
  });

  test('围栏内超限断段：当前片补闭合、下片以原开头行重开，拼接可还原', () {
    // 围栏内容远超 2000 rune：必然在围栏内断段。
    final code = List.generate(
      120,
      (i) => 'const v$i = "代码行$i 一些中文填充内容让行变长一些";',
    ).join('\n');
    final original = '```dart\n$code\n```\n尾部说明。';
    final parts = RemoteCommands.splitOutbound(original);
    expect(parts.length, greaterThan(1));
    for (final part in parts) {
      expect(fenceCount(part) % 2, 0,
          reason: '围栏内断段也须配对:\n'
              '${part.substring(0, part.length.clamp(0, 160))}…');
    }
    expect(parts.first.startsWith('```dart'), isTrue);
    expect(
      parts.skip(1).any((p) => p.startsWith('```dart')),
      isTrue,
      reason: 'S3-7：断段后下片须以原开头行（含语言标注）重开围栏',
    );
    // 还原：剔除「补闭合+重开」注入对（```\n```dart\n）后拼接即原文——
    // 片尾注入的 ``` 前的换行即原行分隔符，注入对整体删除不增不减。
    final restored = parts.join('\n').replaceAll('```\n```dart\n', '');
    expect(restored, original, reason: '剔除围栏注入对后拼接须还原原文');
    // 内容保全：首末代码行均在片中。
    expect(parts.any((p) => p.contains('const v0 =')), isTrue);
    expect(parts.any((p) => p.contains('const v119 =')), isTrue);
    expect(parts.last.contains('尾部说明。'), isTrue);
  });

  test('无围栏参与：拼接还原原文 + 标题优先断段语义保留', () {
    final lines = List.generate(
      300,
      (i) => '普通第$i行中文内容，不含围栏。',
    ).join('\n');
    final text = '# 报告\n$lines';
    final parts = RemoteCommands.splitOutbound(text);
    expect(parts.length, greaterThan(1));
    expect(parts.join('\n'), text, reason: '无围栏参与时拼接必须还原原文');
    expect(parts.first.contains('# 报告'), isTrue, reason: '标题优先断段');
    for (final part in parts) {
      expect(part.runes.length, lessThanOrEqualTo(2000),
          reason: '分片上限 2000 rune 不破坏');
    }
  });

  test('围栏内 "# " 不触发断段；短围栏文本不分片', () {
    expect(
      RemoteCommands.splitOutbound('```\ncode\n```\n\n# 新章节\n正文'),
      ['```\ncode\n```\n\n# 新章节\n正文'],
      reason: '≤2000 rune 不分片',
    );
    final fenced = '```sh\n# 注释行不会断段\n${'x' * 1900}\n```\n# 真章节\n${'y' * 300}';
    final parts = RemoteCommands.splitOutbound(fenced);
    expect(parts.length, greaterThan(1));
    for (final part in parts) {
      expect(fenceCount(part) % 2, 0);
    }
    // 围栏内的 "# 注释行" 与其后代码行必须同片（未被当标题切开）。
    expect(
      parts.any((p) => p.contains('# 注释行') && p.contains('```')),
      isTrue,
    );
  });

  test('文本在围栏内结束：末片补闭合保证配对', () {
    final text = '```dart\n${'final a = 1;\n' * 200}';
    final parts = RemoteCommands.splitOutbound(text);
    expect(parts.length, greaterThan(1));
    for (final part in parts) {
      expect(fenceCount(part) % 2, 0,
          reason: '未闭合围栏须在片内补闭合:\n$part');
    }
  });
}
