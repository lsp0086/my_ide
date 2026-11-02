import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/fs/workspace_fs.dart';
import 'package:path/path.dart' as p;

/// S4-8 迁移：writeText 孤儿 API 已删除（B12——生产零调用，且未来调用方
/// 会绕开写锁/审批/乐观锁）。本文件保留 WorkspaceFs 解析围栏的最小回归：
/// resolveInside 拒绝越界、realpathOf 消别名——原子写语义由
/// AgentTools（apply_patch/write_file）测试覆盖。
void main() {
  late Directory tmp;
  late WorkspaceFs ws;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('wsfs_fence');
    ws = WorkspaceFs(rootPath: tmp.path);
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('resolveInside 拒绝工作区外路径', () {
    expect(
      () => ws.resolveInside(p.join(tmp.parent.path, 'outside.txt')),
      throwsA(isA<FsDeniedException>()),
    );
  });

  test('resolveInside 接受区内相对路径并消别名', () {
    final abs = ws.resolveInside('a/b.txt');
    // macOS /tmp 是 /private/tmp 符号链接：以根目录 realpath 为锚比较。
    final rootReal = ws.resolveInside('.');
    expect(abs == rootReal || p.isWithin(rootReal, abs), isTrue);
  });
}
