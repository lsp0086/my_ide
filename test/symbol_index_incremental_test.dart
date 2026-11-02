import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/lsp/symbol_index.dart';
import 'package:path/path.dart' as p;

void main() {
  test('reindexFile 仅对涉及名称的桶排序：无关桶内容顺序不变', () async {
    final root = await Directory.systemTemp.createTemp('symbol-incr-');
    addTearDown(() async {
      await SymbolIndex.instance.bindProject(null);
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    });
    // 空目录先 bind，后续全走 reindex（避免 bind walk 条目与 reindex
    // canon 条目路径形态不一致导致快照比对失真）。
    await SymbolIndex.instance.bindProject(root.path);
    // unrelated.dart 定义 zeta；touch.dart 定义同名目标 alpha。
    const unrelatedPath = 'unrelated.dart';
    const touchPath = 'touch.dart';
    await File('${root.path}/$unrelatedPath')
        .writeAsString('class zeta {\n}\n');
    await File('${root.path}/$touchPath').writeAsString('class alpha {\n}\n');
    await SymbolIndex.instance.reindexFile(p.join(root.path, unrelatedPath));
    await SymbolIndex.instance.reindexFile(p.join(root.path, touchPath));
    // 无关桶内容快照。
    final zetas = SymbolIndex.instance.allForName('zeta');
    expect(zetas, isNotEmpty);
    final before =
        zetas.map((s) => '${s.filePath}#${s.line}').toList();
    // reindex 与 zeta 无关的文件：touch.dart 内容变化（追加注释改 hash）。
    await SymbolIndex.instance.reindexFile(
      p.join(root.path, touchPath),
      content: 'class alpha {\n}\n// touch\n',
    );
    final after = SymbolIndex.instance
        .allForName('zeta')
        .map((s) => '${s.filePath}#${s.line}')
        .toList();
    expect(after, before, reason: '无关桶 reindex 后内容与顺序应保持快照一致');
  });

  test('reindexFile 涉及桶仍按优先级降序', () async {
    final root = await Directory.systemTemp.createTemp('symbol-incr-sort-');
    addTearDown(() async {
      await SymbolIndex.instance.bindProject(null);
      try {
        if (await root.exists()) await root.delete(recursive: true);
      } catch (_) {}
    });
    // 空目录先 bind（只建 root，不产生 walk 条目，避免 walk 路径与
    // reindex realpath 不一致致旧条目删不掉而复加），后续全走 reindex。
    await SymbolIndex.instance.bindProject(root.path);
    // 故意同名不同优先级：class Foo(100) 与函数 Foo()(80) 同名同桶。
    await File('${root.path}/c.dart')
        .writeAsString('class Foo {\n}\nFoo() {\n}\n');
    await SymbolIndex.instance.reindexFile(p.join(root.path, 'c.dart'));
    await SymbolIndex.instance.reindexFile(
      p.join(root.path, 'c.dart'),
      content: 'class Foo {\n}\nFoo() {\n}\n// touch\n',
    );
    final dupes = SymbolIndex.instance.allForName('Foo');
    expect(
      dupes.map((s) => s.priority).toList(),
      orderedEquals([100, 80]),
    );
  });
}
