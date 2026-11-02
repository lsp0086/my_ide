import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/memory_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('memory-store-');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  File memoryFile(Directory d) => File(p.join(d.path, '.my_ide', 'memory.json'));

  /// 新增条目的非空断言封装：add 对非空 content 必成功（失败仅 warn
  /// 不抛错），测试里直接拿非空 MemoryEntry 用，省层层 !。
  Future<MemoryEntry> mustAdd(
    MemoryStore store,
    String content, {
    String kind = 'other',
  }) async {
    final e = await store.add(content: content, kind: kind);
    expect(e, isNotNull);
    return e!;
  }

  test('B3-4 CRUD 全链路：add/update/remove/list + 落盘可恢复', () async {
    final store = await MemoryStore.init(rootPath: dir.path);
    expect(store.list(), isEmpty);

    final a = await store.add(content: '架构决策：状态管理用 Riverpod', kind: 'decision');
    expect(a, isNotNull);
    expect(a!.kind, 'decision');
    expect(a.id, startsWith('mem-'));
    final b = await store.add(content: '偏好：代码注释一律中文', kind: 'preference');
    expect(b, isNotNull);
    expect(store.list(), hasLength(2));

    // 持久化格式：JSON 数组，字段 {id, content, kind, createdAt, updatedAt}。
    final disk =
        jsonDecode(await memoryFile(dir).readAsString()) as List;
    expect(disk, hasLength(2));
    final first = disk.first as Map;
    expect(first['kind'], 'decision');
    expect(first['content'], '架构决策：状态管理用 Riverpod');
    expect(first.containsKey('createdAt'), isTrue);
    expect(first.containsKey('updatedAt'), isTrue);
    // 时间可解析回 DateTime。
    expect(DateTime.tryParse('${first['createdAt']}'), isNotNull);

    // 空 content 拒收，不落盘。
    expect(await store.add(content: '   '), isNull);
    expect(store.list(), hasLength(2));

    // update：content 变更刷新 updatedAt，createdAt 不变。
    await Future.delayed(const Duration(milliseconds: 5));
    final updated = await store.update(
      a.id,
      content: '架构决策：状态管理用 Riverpod（2026 修订）',
    );
    expect(updated, isNotNull);
    expect(updated!.content, contains('2026 修订'));
    expect(updated.createdAt, a.createdAt);
    expect(
      updated.updatedAt.isAfter(a.updatedAt),
      isTrue,
      reason: 'update 必须刷新 updatedAt',
    );
    // update 不存在的 id 返回 null。
    expect(await store.update('no-such-id', content: 'x'), isNull);
    // update 空白 content 拒收。
    expect(await store.update(a.id, content: '  '), isNull);
    expect(store.list().firstWhere((e) => e.id == a.id).content, updated.content);

    // update 只改 kind：content 不变，kind 归一化（中文别名收敛）。
    final kindChanged = await store.update(a.id, kind: '踩坑');
    expect(kindChanged!.kind, 'pitfall');
    expect(kindChanged.content, updated.content);
    // 无实质变化的 update 不刷 updatedAt。
    final noop = await store.update(a.id, kind: 'pitfall');
    expect(noop!.updatedAt, kindChanged.updatedAt);

    // remove：存在删成功，重复删返回 false（幂等）。
    expect(await store.remove(b!.id), isTrue);
    expect(await store.remove(b.id), isFalse);
    expect(store.list(), hasLength(1));
    final diskAfterRemove =
        jsonDecode(await memoryFile(dir).readAsString()) as List;
    expect(diskAfterRemove, hasLength(1));

    // 新实例（模拟重启/跨会话）从盘恢复，条目与 id 一致。
    final reopened = await MemoryStore.init(rootPath: dir.path);
    expect(reopened.list(), hasLength(1));
    expect(reopened.list().first.id, a.id);
    expect(reopened.list().first.content, updated.content);
  });

  test('读盘容错：文件不存在/JSON 损坏/顶层非数组均用内存态不抛错', () async {
    // 文件不存在：init 直接可用，内存空态。
    var store = await MemoryStore.init(rootPath: dir.path);
    expect(store.list(), isEmpty);

    // 损坏文件（非法 JSON）：解析失败不抛错，按空记忆降级。
    await memoryFile(dir).parent.create(recursive: true);
    await memoryFile(dir).writeAsString('{这不是合法 JSON');
    store = await MemoryStore.init(rootPath: dir.path);
    expect(store.list(), isEmpty);

    // 顶层是对象而非数组：同样容错。
    await memoryFile(dir).writeAsString(jsonEncode({'a': 1}));
    store = await MemoryStore.init(rootPath: dir.path);
    expect(store.list(), isEmpty);

    // 部分坏条目跳过：数组里混入非 Map/空 content 项，好条目照常恢复。
    await memoryFile(dir).writeAsString(jsonEncode([
      'not-a-map',
      {'id': 'bad', 'content': '  '},
      {
        'id': 'ok',
        'content': '好条目',
        'kind': 'pitfall',
        'createdAt': '2026-01-01T00:00:00.000',
        'updatedAt': '2026-01-02T00:00:00.000',
      },
    ]));
    store = await MemoryStore.init(rootPath: dir.path);
    expect(store.list(), hasLength(1));
    expect(store.list().first.id, 'ok');
    expect(store.list().first.kind, 'pitfall');
    expect(store.list().first.createdAt,
        DateTime.parse('2026-01-01T00:00:00.000'));

    // 坏文件上继续写可自愈：新实例读坏盘降级空态，写路径保存新条目
    // 覆写坏盘（读失败不阻断写）。
    await memoryFile(dir).writeAsString('损坏 reset');
    final healed = await MemoryStore.init(rootPath: dir.path);
    expect(healed.list(), isEmpty);
    final recovered = await healed.add(content: '恢复后新增');
    expect(recovered, isNotNull);
    final disk = jsonDecode(await memoryFile(dir).readAsString()) as List;
    expect(disk, hasLength(1));
    expect((disk.first as Map)['content'], '恢复后新增');
  });

  test('search：子串+分词命中，按更新时间倒序，top N 有界', () async {
    final store = await MemoryStore.init(rootPath: dir.path);
    final e1 = await mustAdd(store, '架构决策：状态管理用 Riverpod', kind: 'decision');
    final e2 = await mustAdd(store, '踩坑：Windows 上 rename 前必须先删目标', kind: 'pitfall');
    final e3 = await mustAdd(store, '偏好：代码注释一律中文', kind: 'preference');

    // 子串命中：整 query 存在于 content。
    expect(store.search('Riverpod').map((e) => e.id), [e1.id]);
    // CJK 分词命中：整串「状态管理」不在任何 content，但 2-gram/词
    // 「状态」命中 e1（整串未命中时单字词仍可召回）。
    expect(store.search('状态').map((e) => e.id), contains(e1.id));
    // 无命中返回空。
    expect(store.search('Kubernetes'), isEmpty);
    // 命中多条时按 updatedAt 倒序（e2 比 e1 新）。
    final both = store.search('rename 状态决策 偏好');
    expect(both.map((e) => e.id), containsAll([e1.id, e2.id, e3.id]));

    // 空 query：按更新时间倒序取最近 N 条（e3 最新在最前）。
    final recent = store.search('');
    expect(recent.first.id, e3.id);
    expect(recent.last.id, e1.id);

    // 更新后排序变化：e1 成为最新，搜索排序随之提前。
    await Future.delayed(const Duration(milliseconds: 5));
    await store.update(e1.id, content: '架构决策：状态管理用 Riverpod（修订）');
    expect(store.search('').first.id, e1.id);
    expect(store.search('Riverpod').first.id, e1.id);

    // 有界：灌入 25 条命中项，默认 limit=20 截断，显式 limit 生效。
    for (var i = 0; i < 25; i++) {
      await store.add(content: '批量条目-$i');
    }
    expect(store.search('批量条目').length, MemoryStore.maxSearchResults);
    expect(store.search('批量条目', limit: 5).length, 5);

    // content 长度钳制：超 maxContentLength 截断入库。
    final long = 'x' * (MemoryStore.maxContentLength + 500);
    final entry = await store.add(content: long);
    expect(entry!.content.length, MemoryStore.maxContentLength);
  });

  test('buildMemoryContextBlock：格式与空态', () {
    // 无条目 / 全空白 content 返回 null（调用方不附加空段）。
    expect(buildMemoryContextBlock(const []), isNull);
    final t0 = DateTime.utc(2026, 1, 1);
    expect(
      buildMemoryContextBlock([
        MemoryEntry(id: 'x', content: '   ', kind: 'other', createdAt: t0, updatedAt: t0),
      ]),
      isNull,
    );

    final block = buildMemoryContextBlock([
      MemoryEntry(id: 'a', content: '用 Riverpod', kind: 'decision', createdAt: t0, updatedAt: t0),
      MemoryEntry(id: 'b', content: '注释用中文', kind: 'preference', createdAt: t0, updatedAt: t0),
      MemoryEntry(id: 'c', content: 'Windows rename 三步', kind: 'pitfall', createdAt: t0, updatedAt: t0),
      MemoryEntry(id: 'd', content: '零散记录', kind: 'other', createdAt: t0, updatedAt: t0),
    ])!;
    expect(block, startsWith('【长期记忆】\n'));
    expect(block, contains('- [架构决策] 用 Riverpod'));
    expect(block, contains('- [偏好] 注释用中文'));
    expect(block, contains('- [踩坑] Windows rename 三步'));
    expect(block, contains('- [其他] 零散记录'));
    // 条目间换行拼接，无 id/时间戳泄露给模型。
    expect(block.split('\n'), hasLength(5));
    expect(block, isNot(contains('createdAt')));

    // 未知 kind 归一为「其他」标签。
    expect(
      buildMemoryContextBlock([
        MemoryEntry(id: 'e', content: '未知类型', kind: 'weird', createdAt: t0, updatedAt: t0),
      ]),
      contains('- [其他] 未知类型'),
    );
  });

  test('注入优先级：AGENTS.md 项目规则 > 长期记忆块 > 待办块', () {
    // 规则与记忆冲突时规则优先：项目规则是用户显式契约，恒排在
    // 长期记忆之前注入，模型先生效规则；记忆不得推翻 AGENTS.md。
    final order = memoryInjectionOrderForTest();
    expect(order, [
      MemoryInjectionSlot.projectRules,
      MemoryInjectionSlot.longTermMemory,
      MemoryInjectionSlot.todos,
    ]);
    expect(
      order.indexOf(MemoryInjectionSlot.projectRules),
      lessThan(order.indexOf(MemoryInjectionSlot.longTermMemory)),
    );
    expect(
      order.indexOf(MemoryInjectionSlot.longTermMemory),
      lessThan(order.indexOf(MemoryInjectionSlot.todos)),
    );
    // 槽位标签供 runner 拼装提示与观测。
    expect(order.map((e) => e.label), [
      'AGENTS.md 项目规则',
      '长期记忆块',
      '待办块',
    ]);
  });

  test('并发 add 串行不互盖：多路并发全部落盘（对照 todos 串行队列范式）', () async {
    final store = await MemoryStore.init(rootPath: dir.path);
    const n = 20;
    final ops = <Future<MemoryEntry?>>[];
    for (var i = 0; i < n; i++) {
      ops.add(store.add(content: '并发条目-$i'));
    }
    final created = await Future.wait(ops);
    expect(created.where((e) => e != null).length, n);
    // 内存与盘上均为 n 条，无一被后写盖掉。
    expect(store.list(), hasLength(n));
    final disk = jsonDecode(await memoryFile(dir).readAsString()) as List;
    expect(disk, hasLength(n));
    final contents = disk.map((e) => '${(e as Map)['content']}').toSet();
    for (var i = 0; i < n; i++) {
      expect(contents, contains('并发条目-$i'));
    }
    // id 唯一，无同 id 互覆盖。
    final ids = disk.map((e) => '${(e as Map)['id']}').toSet();
    expect(ids, hasLength(n));

    // 重启恢复后条数不减。
    final reopened = await MemoryStore.init(rootPath: dir.path);
    expect(reopened.list(), hasLength(n));
  });

  test('跨会话合并：外部改盘后下次写自动判脏重载，增量不互盖', () async {
    final store = await MemoryStore.init(rootPath: dir.path);
    await store.add(content: '本会话第一条');

    // 模拟另一会话/进程对 memory.json 做读-改-写（追加外部条目）。
    final external = jsonDecode(await memoryFile(dir).readAsString()) as List;
    final now = DateTime.now().toIso8601String();
    external.add({
      'id': 'mem-external',
      'content': '外部会话写入的踩坑',
      'kind': 'pitfall',
      'createdAt': now,
      'updatedAt': now,
    });
    await memoryFile(dir).writeAsString(jsonEncode(external));

    // 本会话再写：写前判脏重载（size+mtime 双字段探到外部改动），
    // 外部追加项被并回，不被本会话旧快照覆写静默盖掉。
    await store.add(content: '本会话第二条');
    final contents = store.list().map((e) => e.content).toSet();
    expect(contents, contains('本会话第一条'));
    expect(contents, contains('外部会话写入的踩坑'));
    expect(contents, contains('本会话第二条'));

    // 外部改动同样体现在 search 命中（跨会话命中）。
    expect(store.search('外部').map((e) => e.id), contains('mem-external'));
  });

  test('外部删除后 reload 与 add 串行交错：终态以盘为准', () async {
    final store = await MemoryStore.init(rootPath: dir.path);
    await store.add(content: '条目甲');

    // 外部整个删除 memory.json：显式 reload 走串行队列，盘为准清空内存。
    await memoryFile(dir).delete();
    await store.reload();
    expect(store.list(), isEmpty);

    // reload 后的 add：锁内再判脏（文件仍不存在），只落新条目。
    final fresh = await store.add(content: '条目乙');
    expect(fresh, isNotNull);
    expect(store.list().map((e) => e.content), ['条目乙']);
    final disk = jsonDecode(await memoryFile(dir).readAsString()) as List;
    expect(disk, hasLength(1));
    expect((disk.first as Map)['content'], '条目乙');
  });
}
