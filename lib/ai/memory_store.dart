import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/app_logger.dart';
import 'external_content.dart' show wrapUntrustedToolOutput;
// A6-R2：UTF-16 码元截断统一收敛 clipRunes（D17 同口径）——emoji/扩展区
// 中文被 substring 拦腰切断即产生孤代理，后续 JSON 编码/注入围栏解析受损。
import 'remote_channel.dart' show clipRunes;

/// B3-4 事实型长期记忆数据层：用户可管理的事实记忆条目
/// （架构决策 / 偏好 / 踩坑）的增删改查与跨会话命中，落盘
/// `.my_ide/memory.json`（tmp+rename 原子写，读写容错不抛错，
/// 失败仅 AppLogger.warn 留观测点）。
///
/// 设计参照（同项目范式）：
/// - 单例与串行写锁：`SettingsStore.instance` + `_serializedWrite`
///   （读-改-写整表覆写必须单飞串行，并发 add 不互盖）；
/// - 原子写与判脏重载：`agent_tools.dart` 的 todos.json
///   （tmp+pid+微秒+随机数防同名截断；Windows 三步 rename；
///   size+mtime 双字段判脏，外部改盘后下次访问自动重载）。
///
/// 与自动摘要的分界：本 store 是用户/Agent 显式沉淀的「事实记忆」，
/// 与 context_compactor 的自动摘要互补——摘要保任务连续性，
/// 记忆保跨会话可复用的事实。注入优先级见
/// [memoryInjectionOrderForTest]：AGENTS.md 项目规则 > 长期记忆 >
/// 待办块；规则与记忆冲突时规则优先（规则先注入，模型先生效）。
/// 长期记忆条目：`{id, content, kind(decision/preference/pitfall/other),
/// createdAt, updatedAt}`。kind 归一化见 [normalizeMemoryKind]。
class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.content,
    required this.kind,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String content;

  /// 归一化后的类型：decision / preference / pitfall / other。
  final String kind;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 从盘上 JSON 还原条目：单条坏数据（非 Map / content 空）跳过不抛错
  /// （与 todos.json 同口径的读盘容错）。缺失 id 用 [fallbackId] 补位，
  /// 时间解析失败回落当前时刻，坏字段不让整份记忆不可读。
  static MemoryEntry? fromJson(Object? raw, {String? fallbackId}) {
    if (raw is! Map) return null;
    final content = '${raw['content'] ?? ''}'.trim();
    if (content.isEmpty) return null;
    final id = '${raw['id'] ?? ''}'.trim();
    return MemoryEntry(
      id: id.isEmpty ? (fallbackId ?? 'mem-unknown') : id,
      content: content,
      kind: normalizeMemoryKind('${raw['kind'] ?? ''}'),
      createdAt: _parseTime(raw['createdAt']) ?? DateTime.now(),
      updatedAt: _parseTime(raw['updatedAt']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'content': content,
        'kind': kind,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static DateTime? _parseTime(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        return DateTime.parse(raw.trim());
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

/// kind 归一化：大小写/别名/中文一律收敛到四枚举；毒值按 other 放行
/// （与 todos `_normalizeTodoStatus` 同口径——记忆是软数据，拒收会让
/// 用户显式沉淀的事实静默丢失，归 other 最稳）。
String normalizeMemoryKind(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'decision':
    case 'decisions':
    case 'arch':
    case '架构决策':
    case '决策':
      return 'decision';
    case 'preference':
    case 'preferences':
    case 'pref':
    case '偏好':
      return 'preference';
    case 'pitfall':
    case 'pitfalls':
    case '踩坑':
      return 'pitfall';
    default:
      return 'other';
  }
}

/// 注入块用的中文类型标签（未知 kind 归「其他」）。
String memoryKindLabel(String kind) {
  switch (kind) {
    case 'decision':
      return '架构决策';
    case 'preference':
      return '偏好';
    case 'pitfall':
      return '踩坑';
    default:
      return '其他';
  }
}

/// B3-4 注入块构造（纯函数，供 runner 注入与测试断言）：
/// 把长期记忆条目拼成系统提示 injection 段，形如
/// `【长期记忆】\n- [架构决策] ...\n- [偏好] ...`。
/// 无条目（或全部条目 content 为空）返回 null——调用方据此不附加，
/// 不给模型塞空段。
String? buildMemoryContextBlock(List<MemoryEntry> entries) {
  final lines = <String>[];
  for (final e in entries) {
    final content = e.content.trim();
    if (content.isEmpty) continue;
    lines.add('- [${memoryKindLabel(e.kind)}] $content');
  }
  if (lines.isEmpty) return null;
  return '【长期记忆】\n${lines.join('\n')}';
}

/// B3-4 注入优先级槽位：runner 组装系统提示时的三段来源。
/// 顺序即优先级——模型读到即先生效（prompt 靠前压制靠后）。
enum MemoryInjectionSlot {
  /// AGENTS.md 项目规则（工作区契约，用户显式约定，最高优先）。
  projectRules,

  /// 长期记忆块（buildMemoryContextBlock 产物）。
  longTermMemory,

  /// 待办块（context_compactor.buildTodosStatusBlock 产物）。
  todos;

  String get label {
    switch (this) {
      case MemoryInjectionSlot.projectRules:
        return 'AGENTS.md 项目规则';
      case MemoryInjectionSlot.longTermMemory:
        return '长期记忆块';
      case MemoryInjectionSlot.todos:
        return '待办块';
    }
  }
}

/// B3-4 注入优先级纯函数（供 runner 注入与测试断言）。
///
/// 固定顺序：AGENTS.md 项目规则 > 长期记忆块 > 待办块。
/// 语义说明（任务要求）：**规则与记忆冲突时规则优先**——项目规则是
/// 用户写在仓库里的显式契约，记忆是历史沉淀的事实，注入顺序上规则
/// 恒在记忆之前，模型先生效规则；测试按本顺序断言注入编排。
///
/// 待办块垫底：待办是易变的任务进度，与事实记忆冲突时应让位于
/// 架构决策/偏好/踩坑等长期事实。
List<MemoryInjectionSlot> memoryInjectionOrderForTest() => const [
      MemoryInjectionSlot.projectRules,
      MemoryInjectionSlot.longTermMemory,
      MemoryInjectionSlot.todos,
    ];

/// B3-4 注入块盘读（与 context_compactor.buildTodosStatusBlock 同范式）：
/// runner 每轮调用，直接从 `<root>/.my_ide/memory.json` 读最新记忆拼块，
/// 不依赖单例初始化顺序（UI 面板/Agent 工具写入后即时可见）。
/// 文件不存在/超 1MB/解析失败/无有效条目返回 null（调用方不附加）。
/// A6-R2：memory.json 是模型可写文件（memory_write 类工具落盘），内容属
/// 不可信外部数据——非空块统一包 wrapUntrustedToolOutput 围栏（上轮恶意
/// 页诱导写入记忆，下一轮以 system 特权直进的跨轮注入链），同时调用方
/// 据非空块 markUntrustedThisTurn 提级写/命令审批。
Future<String?> buildMemoryStatusBlock(String? rootPath) async {
  if (rootPath == null || rootPath.isEmpty) return null;
  try {
    final f = File(p.join(rootPath, '.my_ide', 'memory.json'));
    if (!await f.exists()) return null;
    // 与 todos.json 同口径的体积上限：记忆是少量事实条目，超大文件
    // 视为外部损坏，直接跳过不整量解码。
    if (await f.length() > MemoryStore.maxDiskBytes) return null;
    final decoded = jsonDecode(await f.readAsString());
    if (decoded is! List) return null;
    final entries = <MemoryEntry>[];
    for (var i = 0; i < decoded.length && entries.length < 50; i++) {
      final entry = MemoryEntry.fromJson(
        decoded[i],
        fallbackId: 'mem-$i',
      );
      if (entry != null) entries.add(entry);
    }
    final block = buildMemoryContextBlock(entries);
    if (block == null) return null;
    // A6-R2：围栏化返回（source=memory），非空块由调用方计入本轮不可信。
    return wrapUntrustedToolOutput(source: 'memory', body: block);
  } catch (_) {
    return null;
  }
}

/// B3-4 长期记忆 store：按项目根隔离（`.my_ide/memory.json`），
/// 单例 + 串行写锁（参考 [SettingsStore.instance] 范式）。
///
/// 写路径：add/update/remove 一律走 `_serializedWrite` 单飞队列，
/// 锁内先按判脏戳重载盘上最新值（外部改盘/多窗口增量不丢），
/// 再读-改-写整表原子覆写；落盘失败仅 warn 不抛错。
/// 读路径：list/search 走内存态（同步零 IO）；跨会话/跨进程的
/// 外部改动由每次写前的判脏重载兜底（同 todos.json 范式）。
class MemoryStore extends ChangeNotifier {
  MemoryStore._(this._rootPath);

  static MemoryStore? _instance;
  static MemoryStore get instance => _instance!;
  static MemoryStore? get maybeInstance => _instance;

  /// D6-L12：memory.json 读盘体积上限（与 buildMemoryStatusBlock 同一
  /// 常量对齐）——读前 stat 预检，超大文件（外部损坏/误写）不整量
  /// readAsString+jsonDecode（GB 级即 OOM）。
  static const int maxDiskBytes = 1024 * 1024;

  /// 绑定项目根并完成首次加载；重复 init 换绑新项目根（切项目场景）。
  /// 读盘容错：文件不存在/解析失败均不抛错，按内存空态可用。
  static Future<MemoryStore> init({required String rootPath}) async {
    final store = MemoryStore._(rootPath);
    _instance = store;
    await store._loadFromDiskIfNeeded();
    return store;
  }

  final String _rootPath;
  final List<MemoryEntry> _entries = [];

  /// 写锁排队尾（已吞错的 Future）：与 SettingsStore._serializedWrite
  /// 同口径，后到写等前序写落盘再执行，同一时刻仅一个写体运行。
  Future<void>? _pendingWrite;

  /// 判脏戳：size+mtime 双字段（同 todos.json 口径）——同毫秒两写/
  /// 低精度文件系统下单 mtime 相等即漏检外部改动。仅解析成功后更新，
  /// 解析失败保持旧戳允许下次访问重试（坏文件被修复后能恢复）。
  String? _diskStamp;

  static final Random _rng = Random.secure();

  /// search 默认返回上限（有界，防命中集过大撑爆 prompt）。
  static const int maxSearchResults = 20;

  /// 单条 content 长度钳制（与 todos 200 字段同思路放宽到 2000：
  /// 事实记忆常含命令/配置片段，截断防注入块臃肿）。
  static const int maxContentLength = 2000;

  File get _file => File(p.join(_rootPath, '.my_ide', 'memory.json'));

  String _newId() =>
      'mem-${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}';

  /// A6-R2：按 rune 截断（clipRunes）——此前按 UTF-16 码元 substring，
  /// 截点落在代理对中间即产生孤代理（emoji/扩展区中文记忆条目损坏）。
  String _clampContent(String text) => clipRunes(text, maxContentLength);

  /// 单飞串行化：后到写排队等前序写完成再执行；锁内不得再调本方法
  /// （死锁），复合写用内部无锁体。
  Future<T> _serializedWrite<T>(Future<T> Function() action) {
    final prev = _pendingWrite;
    final Future<void> waited = prev == null
        ? Future<void>.value()
        : prev.then<void>((_) {}, onError: (Object _) {});
    final next = waited.then((_) => action());
    _pendingWrite = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// 从 .my_ide/memory.json 恢复（判脏重载，读写容错）。
  /// - 文件不存在：内存清空（盘为准）；
  /// - 解析失败/顶层非数组：保留内存态并 warn 可观测，不抛错；
  /// - 已加载且 size+mtime 未变：直接用内存态，不重读。
  Future<void> _loadFromDiskIfNeeded() async {
    try {
      if (!await _file.exists()) {
        _diskStamp = null;
        _entries.clear();
        return;
      }
      final stat = await _file.stat();
      final stamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      if (_diskStamp == stamp) return;
      // D6-L12：读前体积上限——超大 memory.json 整量解码即 OOM；超限
      // 视为外部损坏，跳过解码沿用内存态，warn 可观测。刷判脏戳防同一
      // 坏文件每次写前重复 warn（文件被修复后 mtime 变化自然重试）。
      if (stat.size > maxDiskBytes) {
        _diskStamp = stamp;
        AppLogger.instance.warn(
          'memory',
          'memory.json 超过 $maxDiskBytes 字节上限，按损坏跳过读取',
        );
        return;
      }
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! List) {
        AppLogger.instance.warn('memory', 'memory.json 顶层不是数组，按空记忆处理');
        return;
      }
      final next = <MemoryEntry>[];
      for (var i = 0; i < decoded.length; i++) {
        final entry =
            MemoryEntry.fromJson(decoded[i], fallbackId: 'mem-restored-$i');
        if (entry != null) next.add(entry);
      }
      _entries
        ..clear()
        ..addAll(next);
      // 解析成功才刷判脏戳：失败时保持旧戳，坏文件被外部修复后下次
      // 访问可重载恢复，不会"一次失败永不重试"。
      _diskStamp = stamp;
    } catch (e) {
      // 读坏盘不阻断业务：沿用内存态，仅 warn 留观测点
      // （与 todos.json 读盘容错同口径，不静默吞到无迹可查）。
      AppLogger.instance.warn('memory', 'memory.json 读取失败，沿用内存态', e);
    }
  }

  /// 显式重载（外部手工编辑 memory.json / 多进程改动后的刷新入口）。
  /// 走串行队列，避免与在途写交错读到半新半旧。
  Future<void> reload() => _serializedWrite(() => _loadFromDiskIfNeeded());

  /// 原子写落盘（tmp+flush+rename，Windows 三步）。
  /// 同微秒同进程互盖修复：tmp 名带 pid+微秒+32bit 随机，并发两写
  /// 不同名不互截。任一步失败仅 AppLogger.warn 不抛错、清残 tmp。
  Future<void> _saveToDisk() async {
    final dir = Directory(p.join(_rootPath, '.my_ide'));
    final target = File(p.join(dir.path, 'memory.json'));
    final tmp = File(
      '${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}',
    );
    try {
      await dir.create(recursive: true);
      await tmp.writeAsString(
        jsonEncode([for (final e in _entries) e.toJson()]),
        flush: true,
      );
      File? bak;
      if (Platform.isWindows && await target.exists()) {
        bak = File('${target.path}.myide-bak');
        try {
          if (await bak.exists()) await bak.delete();
        } catch (_) {}
        await target.rename(bak.path);
      }
      try {
        await tmp.rename(target.path);
      } catch (e) {
        if (bak != null && await bak.exists()) {
          try {
            await bak.rename(target.path);
          } catch (_) {}
        }
        rethrow;
      }
      if (bak != null && await bak.exists()) {
        try {
          await bak.delete();
        } catch (_) {}
      }
      // 落盘后刷新判脏戳，避免下次读取误判外部改动重载丢内存态。
      try {
        final stat = await target.stat();
        _diskStamp = '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
      } catch (_) {}
    } catch (e) {
      AppLogger.instance.warn('memory', 'memory.json 落盘失败', e);
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 当前全部条目（插入序，新条目在后）。同步零 IO，返回不可变快照。
  List<MemoryEntry> list() => List.unmodifiable(_entries);

  /// B3-4：新增记忆条目。content trim 后为空拒收（返回 null）；
  /// 超过 [maxContentLength] 截断。id/时间戳由 store 生成。
  /// 串行锁内先判脏重载再追加落盘，并发 add 不互盖。
  Future<MemoryEntry?> add({
    required String content,
    String kind = 'other',
  }) {
    final text = content.trim();
    if (text.isEmpty) return Future.value(null);
    final clamped = _clampContent(text);
    final normalizedKind = normalizeMemoryKind(kind);
    return _serializedWrite(() async {
      await _loadFromDiskIfNeeded();
      final now = DateTime.now();
      final entry = MemoryEntry(
        id: _newId(),
        content: clamped,
        kind: normalizedKind,
        createdAt: now,
        updatedAt: now,
      );
      _entries.add(entry);
      await _saveToDisk();
      notifyListeners();
      return entry;
    });
  }

  /// 更新条目 content / kind（可只改其一）；createdAt 不变，
  /// 内容或类型确有变化时刷新 updatedAt。id 不存在返回 null；
  /// 新 content 为空白拒收（返回 null，不落盘）。
  Future<MemoryEntry?> update(
    String id, {
    String? content,
    String? kind,
  }) {
    return _serializedWrite(() async {
      await _loadFromDiskIfNeeded();
      final i = _entries.indexWhere((e) => e.id == id);
      if (i < 0) return null;
      final cur = _entries[i];
      if (content != null) {
        final text = content.trim();
        if (text.isEmpty) return null;
      }
      final nextContent = content == null
          ? cur.content
          : _clampContent(content.trim());
      final nextKind = kind == null ? cur.kind : normalizeMemoryKind(kind);
      // 无实质变化直接返回原条目，不刷 updatedAt 不落盘。
      if (nextContent == cur.content && nextKind == cur.kind) return cur;
      final updated = MemoryEntry(
        id: cur.id,
        content: nextContent,
        kind: nextKind,
        createdAt: cur.createdAt,
        updatedAt: DateTime.now(),
      );
      _entries[i] = updated;
      await _saveToDisk();
      notifyListeners();
      return updated;
    });
  }

  /// 删除条目；返回是否删掉（幂等：删不存在的 id 返回 false）。
  Future<bool> remove(String id) {
    return _serializedWrite(() async {
      await _loadFromDiskIfNeeded();
      final i = _entries.indexWhere((e) => e.id == id);
      if (i < 0) return false;
      _entries.removeAt(i);
      await _saveToDisk();
      notifyListeners();
      return true;
    });
  }

  /// B3-4：跨会话命中检索——子串 + 分词命中（CJK 连续串补 2-gram
  /// 滑窗粒度，整串未命中时单字词仍可命中），按 updatedAt 倒序
  /// （最近沉淀的事实优先），返回 top N（默认 [maxSearchResults] 有界）。
  /// 空 query 视为「取最近 N 条」，供无 query 的整段注入场景。
  List<MemoryEntry> search(String query, {int limit = maxSearchResults}) {
    final sorted = List<MemoryEntry>.of(_entries)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return sorted.take(limit).toList();
    }
    final tokens = _tokenize(q);
    final hits = <MemoryEntry>[];
    for (final e in sorted) {
      final content = e.content.toLowerCase();
      if (content.contains(q) || tokens.any(content.contains)) {
        hits.add(e);
        if (hits.length >= limit) break;
      }
    }
    return hits;
  }

  /// 查询分词：按空白与常见标点切分；CJK 连续串（长度 > 2）追加
  /// 2-gram 滑窗，避免「架构决策」类整串分词后单字词丢失粒度。
  static List<String> _tokenize(String q) {
    final parts = q
        .split(RegExp(
            r'''[\s,，。、;；:：!！?？/\\|()+\[\]{}<>"'`~@#$%^&*_+\-]+'''))
        .where((e) => e.isNotEmpty)
        .toList();
    final tokens = <String>{};
    for (final part in parts) {
      tokens.add(part);
      if (part.length > 2 && _isCjkWord(part)) {
        for (var i = 0; i + 2 <= part.length; i++) {
          tokens.add(part.substring(i, i + 2));
        }
      }
    }
    return tokens.toList();
  }

  static bool _isCjkWord(String s) =>
      s.runes.every((r) => _isCjkRune(r) || r == 0x3000);

  static bool _isCjkRune(int r) =>
      (r >= 0x4E00 && r <= 0x9FFF) ||
      (r >= 0x3400 && r <= 0x4DBF) ||
      (r >= 0x20000 && r <= 0x2A6DF) ||
      (r >= 0x3040 && r <= 0x30FF) ||
      (r >= 0xAC00 && r <= 0xD7AF) ||
      (r >= 0x3000 && r <= 0x303F) ||
      (r >= 0xFF00 && r <= 0xFFEF);
}
