import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data' show BytesBuilder;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../diagnostics/app_logger.dart';
import '../diagnostics/telemetry.dart';
import '../fs/workspace_fs.dart';
import 'git_anchor.dart';
import 'git_worktree.dart';
import 'shadow_store.dart';
part 'checkpoint_store_manifest.dart';
part 'checkpoint_store_atomic.dart';
part 'checkpoint_store_blobs.dart';
part 'checkpoint_store_diffing.dart';
part 'checkpoint_store_restore.dart';
part 'checkpoint_store_revert.dart';
part 'checkpoint_store_models.dart';
part 'checkpoint_store_persist.dart';
part 'checkpoint_store_capture.dart';
part 'checkpoint_store_commit.dart';
part 'checkpoint_store_undo.dart';

/// 自研版本底层：工作区是唯一完整文本；版本库只记差量。
///
/// 目录结构：.my_ide/versions/
///   manifest.json
///   objects/blobs/ab/cdef...   仅二进制按 SHA1 存一份字节（文本不落 blob）
///   trees/id.json              每版只记 path → hash（身份，不含正文）
///   diffs/id.json              相对上一版的文件级 + 行级 unified diff
///
/// 文本恢复 = 按 diff 链重建；二进制恢复 = blob 字节。
/// 旧版 snapshots/id/ 与历史文本 blob 仍可读（兼容），新 checkpoint 不再写文本副本。
class CheckpointStore extends ChangeNotifier {
  static bool Function(String rel)? debugFailBeforeRename;
  // B4 测试钩子：恢复落盘前复检环节注入外部改动（模拟复检→落盘窗口漂移），
  // 该窗口无法从测试外部定时命中，按 debugFailBeforeRename 同惯例注入。
  static Future<void> Function(String rel)? debugModifyBeforeRestoreApply;
  // S4-4 测试钩子：漂移复检（建保险→复检）窗口注入外部改动，验证中止前
  // redo 保险弹栈回收；窗口无法从测试外部定时命中，同上惯例注入。
  static Future<void> Function()? debugBeforeRestoreRecheck;
  String? _rootPath;
  Directory? _versionsDir;
  /// A4-10：bindProject 时 versions 目录创建失败的可读错误——置 null
  /// 前留痕（AppLogger.warn 同步落盘），版本面板/调用方据此提示用户
  /// "版本库不可用及原因"，不再无声失效。成功绑定即清空。
  String? _versionsDirError;

  /// A4-10：版本库目录不可用的可见错误（null=可用或未绑定项目）。
  String? get versionsDirError => _versionsDirError;

  List<CheckpointInfo> _checkpoints = [];
  // R2-CK1：manifest成功加载标记——主备双坏时内存为空但磁盘tree/diff仍在，
  // 此时_gcOrphanArtifacts以live={}删光全库。未成功加载即不删。
  bool _manifestLoaded = false;
  final Map<String, List<FileChange>> _diffCache = {};
  final Map<String, Map<String, String>> _treeCache = {};
  // R9-缓存有界：长会话翻版本即 _diffCache/_treeCache 只增不收，
  // 此前无界。现超 64 条丢最旧，与 WorkspaceSearch 64 上限同口径。

  bool _busy = false;
  // B1：借位计数——外层版本操作（revert*/单文件/单块回退）已占 _busy 时，
  // 内部 _safetyCheckpointIfDrifted 经本计数借位重入 checkpoint()，不再临时
  // 清零 _busy（清零窗口曾放行第二路并发落盘）。借位仅限本 store 内部调用。
  int _busyBorrow = 0;

  /// B13：工作区快照条目上限——大仓此前每轮 checkpoint/restore 全量枚举
  /// +逐文件读，无界拖垮轮次耗时与内存。超限截断（与 AgentTools
  /// _snapshotWorkspace 5000 上限同口径）。
  static const captureMaxEntries = 5000;

  /// B13：条目上限的测试覆写——本地构造 5000+ 文件再全量 diff 代价过高，
  /// 测试注入小上限验证截断旗标与有界扫描；生产路径为 null 不生效。
  @visibleForTesting
  static int? debugCaptureMaxEntriesOverrideForTest;

  /// B13：最近一次 _captureWorkspace 是否截断。截断旗标可见性：生产侧打
  /// warn 日志 + 本测试 getter。截断哨兵不注入树表——树表经 _writeTree
  /// 持久化、_diffTrees/_materializeDiffs 按真实文件处理，注入哨兵键会
  /// 破坏版本链；复用 AgentTools.snapshotTruncatedKey 的"可见截断旗标"
  /// 口径改由本字段+日志呈现。
  bool _lastCaptureTruncated = false;

  /// B13：测试可见的截断旗标（最近一次 _captureWorkspace）。
  @visibleForTesting
  bool get debugLastCaptureTruncatedForTest => _lastCaptureTruncated;

  /// B1：对“其他调用方”是否处于锁定态——借位期间（_busyBorrow>0）内部
  /// 重入放行，外部新调用仍按 _busy 直查拒绝（revert/restore 等入口不放宽）。
  bool get _lockedForOthers => _busy && _busyBorrow == 0;
  // R2-06 restore 全局世代：restore 在途时 AgentTools 写盘侧排队等待，
  // 而非仅事后指纹中止。静态共享（单进程单工作区现状），旧世代晚到直接丢。
  // 第3轮R3-1：实例世代——双窗口同进程开不同rootPath时，A restore推进全局
  // 世代会让B写盘误等/误放行。现实例计数为主，静态仅兼容观测（旧单测/全局探针）。
  static int _restoreGen = 0;
  int _restoreGenLocal = 0;
  int get restoreGen => _restoreGenLocal;
  void _bumpRestoreGen() {
    _restoreGenLocal++;
    _restoreGen++;
  }
  // drop 重入位：revertDropVersions 外层已占 _busy，内层 drop 借位重入，
  // 外部并发仍抛错。直接调 drop 此前无 guard 会与 checkpoint 交错丢 manifest。
  int _dropReentrancy = 0;
  final Random _rng = Random.secure();
  // Redo 栈：Restore 前把「目标 → 现场」的反向差量入栈，不保留完整文本。
  final List<List<FileChange>> _redoPatches = [];
  final List<String> _redoLabels = [];
  // D3-S2：每条 Redo 保险对应的"恢复后基线树指纹"——Redo 回放前复检，
  // 漂移即中止，防 restore 后用户/Agent 写入被 Redo 静默删除/内容错乱。
  final List<String> _redoBaseDigests = [];

  String? get rootPath => _rootPath;
  List<CheckpointInfo> get checkpoints => List.unmodifiable(_checkpoints);
  bool get busy => _busy;
  bool get canRedo => _redoPatches.isNotEmpty;
  List<String> get redoLabels => List.unmodifiable(_redoLabels);

  /// extension 分域拆分桥接：ChangeNotifier.notifyListeners 标注
  /// @protected/@visibleForTesting，extension 成员调用触发 lint；
  /// 分域 part 统一经此入口广播（与 notifyListeners 行为一致）。
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  void notifyVersionChanged() => notifyListeners();

  /// R3-04/B6：多窗口 manifest 互斥合并已下沉进 [_saveManifest]——
  /// 所有写路径（checkpoint/dropVersions/revertSingleFile/revertSingleHunk）
  /// 统一在保存前重读磁盘 manifest 与内存并集（内存优先），不再依赖个别
  /// 调用点记得先合并。
  /// B6：待删节点墓碑——dropVersions/revert* 摘除节点后、磁盘 manifest
  /// 尚未更新前调用保存时，合并不得把刚摘除的节点从磁盘并回来（否则
  /// 上限 GC 永不生效），故合并跳过本集合内的 id。
  Set<String> _pendingDropTombstones = const <String>{};

  /// 原子保存：tmp 写盘 + flush + rename，旧 manifest 留 .bak。
  /// 先写 `.new` 再 rename 成 `.bak`：copy 非原子，崩溃可双坏；
  /// `.new` 写坏只影响备份链，主文件仍可用。
  /// B6：保存前统一执行多窗口合并（原 _mergeManifestBeforeSave 下沉至此）——
  /// 重读磁盘 manifest，磁盘有而内存没有的节点（他窗新落盘）并入内存
  /// （内存优先：同 id 以内存版本为准；_pendingDropTombstones 内的本窗
  /// 待删节点跳过不并入），合并后再写回，所有写路径不再丢他窗节点。
  /// S4-5：进程内按路径串行链——同一路径的 manifest 保存严格串行，
  /// 消除同进程多 Store（双窗）读-改-写交错丢节点；跨进程互斥由文件锁承接。
  static final Map<String, Future<void>> _manifestSaveChain = {};

  /// S4-5：跨进程文件锁——`.my_ide/versions/manifest.lock` 上拿排它锁，
  /// 有竞争时轮询至 5s 后降级无锁保存（降级不阻塞主流程）。不用
  /// `lockSync(FileLock.blocking)`：blocking 无超时手段且会同步卡死
  /// UI isolate，与"5s 超时降级不阻塞"矛盾；非阻塞 exclusive 锁轮询
  /// 语义等同（flock 互斥）且可超时。
  static Future<RandomAccessFile?> _acquireManifestLock(
    Directory versions,
  ) async {
    RandomAccessFile? raf;
    try {
      final lockFile = File(p.join(versions.path, 'manifest.lock'));
      try {
        await lockFile.parent.create(recursive: true);
      } catch (_) {}
      raf = await lockFile.open(mode: FileMode.append);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (true) {
        try {
          raf.lockSync(FileLock.exclusive);
          return raf;
        } catch (_) {}
        if (DateTime.now().isAfter(deadline)) {
          // R-LOCK-LEAK：超时降级前关闭已 open 的句柄——此前 return null
          // 直接返回，每次跨进程锁竞争超时都泄漏一个 RandomAccessFile，
          // 多窗口高频 manifest 写下属持续累积。
          try {
            await raf.close();
          } catch (_) {}
          return null;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      return null;
    }
  }

  /// R-ATOMIC-RETRY：rename 重试，不做非原子直写回退。
  static Future<void> _renameWithRetry(File tmp, File target) async {
    Object? lastError;
    const backoff = [
      Duration(milliseconds: 5),
      Duration(milliseconds: 25),
      Duration(milliseconds: 50),
    ];
    for (final wait in [...backoff, null]) {
      if (wait != null) {
        await Future<void>.delayed(wait);
      }
      try {
        await tmp.rename(target.path);
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError(
      '原子 rename 重试失败（目标可能被占用）：${target.path}：$lastError',
    );
  }

  static bool _isHexHash(String hash) =>
      hash.isNotEmpty &&
      hash.length <= 128 &&
      RegExp(r'^[0-9a-f]+$').hasMatch(hash);

  /// 版本 id 门禁：12 hex（兼容旧 snapshots 目录名），防 `../` 穿越。
  static bool _isSafeVersionId(String id) =>
      id.isNotEmpty && id.length <= 64 && RegExp(r'^[0-9a-f]+$').hasMatch(id);

  /// 版本上限：prefs versionMaxNodes，默认 100，钳制 20~500。
  static Future<int> versionMaxNodes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt('versionMaxNodes') ?? 100).clamp(20, 500);
    } catch (_) {
      return 100;
    }
  }

  /// 扫描工作区：文本只记 hash，二进制才写 blob。
  /// 快照忽略目录：与文件树/符号索引同口径，避免 node_modules 等大目录
  /// 全量扫描爆内存。此前只忽略 .my_ide/.git，200MB log 照样读。
  static const _snapshotSkipDirs = {
    '.my_ide',
    '.git',
    'node_modules',
    '.dart_tool',
    'build',
    'dist',
    'out',
    'coverage',
    '.next',
    'Pods',
    'DerivedData',
    '__pycache__',
    '.venv',
    'venv',
    'vendor',
    'target',
  };

  static bool _isSnapshotSkipped(String rel) {
    // 与 AgentTools._snapshotSkipped 同口径：任一段命中即跳过，
    // 此前只看首段，`a/node_modules` 不跳过致快照口径不一致。
    for (final part in rel.split(RegExp(r'[/\\]'))) {
      if (_snapshotSkipDirs.contains(part)) return true;
    }
    return false;
  }

  /// 工作区树指纹：restore 建保险前后比对，漂移即中止避免丢写。
  /// key 排序后拼 `path=hash` 再 sha1，避免 map 迭代序抖动。
  static String _treeDigest(Map<String, String> tree) {
    final keys = tree.keys.toList()..sort();
    final buf = StringBuffer()
      ..write(keys.length)
      ..write('\n');
    for (final k in keys) {
      buf.write(k);
      buf.write('=');
      buf.write(tree[k]);
      buf.write('\n');
    }
    return sha1.convert(utf8.encode(buf.toString())).toString();
  }

  /// R2-06 写盘侧排队：AgentTools 写盘前调此等待在途 restore。
  /// R2-02 稳静窗口防间隙醒早：busy+gen双条件不足——restore1结束
  /// （busy=false, gen已推进）到restore2开始（busy=true）存在间隙，
  /// 只看“busy=false且gen推进”仍在间隙醒早。现要求busy=false持续
  /// 稳静200ms才放行；新restore在窗口内启动即重新等待。
  /// 无在途（busy=false）直接返回。
  /// B7：enterGen 死参落地——[enterGen] 为写盘侧进入时记录的世代，
  /// 醒后比对：进入后世代已推进（审批/排队窗口内发生过 restore）或
  /// 等待期间任何世代推进（restore 开始/结束都 bump，瞬时完成整个
  /// 生命周期时 50ms 轮询可能漏采 busy 变化）都重置稳静窗口重等，
  /// 消除死参语义缺口。
  static Future<void> waitForNoRestore({
    required int enterGen,
    required bool Function() restoreBusy,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!restoreBusy() && currentRestoreGen == enterGen) return;
    final deadline = DateTime.now().add(timeout);
    DateTime? quietSince;
    var lastGen = enterGen;
    while (true) {
      if (!DateTime.now().isBefore(deadline)) {
        throw StateError('等待恢复完成超时');
      }
      final nowGen = currentRestoreGen;
      if (restoreBusy() || nowGen != lastGen) {
        lastGen = nowGen;
        quietSince = null;
      } else {
        quietSince ??= DateTime.now();
        if (DateTime.now().difference(quietSince) >=
            const Duration(milliseconds: 200)) {
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 当前 restore 世代：写盘侧进入时记录，调 waitForNoRestore 等推进。
  static int get currentRestoreGen => _restoreGen;

  /// B6：有界读文件——openRead(0, cap+1)，读入超过 [cap] 返回 null。
  /// 恢复链此前两处"length 判定→readAsBytes/readAsString 全量读"之间存在
  /// TOCTOU 窗口（读前文件被涨大即全量进内存）。提前 break 由 await-for
  /// 自动取消订阅，FD 不泄漏；openRead 的 IO 错误原样上抛（调用方按原
  /// 读失败口径处理）。
  static Future<List<int>?> readFileBounded(File file, int cap) async {
    final chunks = <int>[];
    var total = 0;
    await for (final part in file.openRead(0, cap + 1)) {
      chunks.addAll(part);
      total += part.length;
      if (total > cap) return null;
    }
    return chunks;
  }

  /// B1-10：解析 unified diff 为 hunk 列表。
  ///
  /// static + ForTest 命名按项目惯例暴露（xxxForTest），diff_view 的
  /// hunk 勾选与本单测共用同一份口径，两侧下标不错位。
  ///
  /// 口径与 [_lineDiffText] 生成侧、diff_view 分组一致：
  /// - `@@ -a,b +c,d @@` 可解析即开新块（与 diff_view 按头分块同序）；
  /// - `diff `/`index `/`---`/`+++`/`@@` 收块；`\ No newline` 标记行不占行；
  /// - 中部裸空行按空上下文行进块（R4-A2 同口径），仅 split 产生的
  ///   末尾空串（diff 以换行收尾）被忽略；
  /// - 头不可信（手拼/截断/行号溢出）跳过该块，不抛错、不编造行号。
  static List<DiffHunk> parseDiffHunksForTest(String diff) {
    final hunks = <DiffHunk>[];
    if (diff.isEmpty) return hunks;
    final lines = diff.split('\n');
    // 与 diff_view._parseUnifiedDiff 同一套头正则（计数可省略，省略按 1 行计）。
    final head = RegExp(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');
    var i = 0;
    while (i < lines.length) {
      final raw = lines[i];
      if (raw.isEmpty || !raw.startsWith('@@')) {
        i++;
        continue;
      }
      final m = head.firstMatch(raw);
      final oldStart = m == null ? null : int.tryParse(m.group(1)!);
      final newStart = m == null ? null : int.tryParse(m.group(3)!);
      if (m == null || oldStart == null || newStart == null) {
        // 头解析失败：块跳过（行号不可信，套用只会写坏文件）。
        i++;
        continue;
      }
      final body = <String>[];
      i++;
      while (i < lines.length) {
        final line = lines[i];
        if (line.startsWith('@@') ||
            line.startsWith('diff ') ||
            line.startsWith('index ') ||
            line.startsWith('---') ||
            line.startsWith('+++')) {
          break;
        }
        if (line.startsWith('\\')) {
          // “\ No newline at end of file” 标记行：不占行。
          i++;
          continue;
        }
        if (line.isEmpty) {
          // 中部裸空行即空上下文行；末尾换行产物（split 产生的空串）忽略。
          if (i == lines.length - 1) break;
          body.add(' ');
          i++;
          continue;
        }
        body.add(line);
        i++;
      }
      hunks.add(DiffHunk.build(oldStart, newStart, body));
    }
    return hunks;
  }

  /// hunk 定位容错窗口：头行号与既有写法不一致（外部 diff / 上下文行被
  /// 邻居块吃掉）时在期望位置附近就近找锚，仍找不到即放弃该块。
  static const _hunkFuzzWindow = 64;

  /// B1-10：按用户勾选应用部分 hunk，返回应用后的完整文件内容。
  ///
  /// - 空勾选 → 原样返回 [baseContent]（等价"全部拒绝"，不写坏文件）；
  /// - 非法/越界下标忽略，只按升序应用合法勾选，任何情况下都不抛错
  ///   （UI 可直接调用）；
  /// - 逐块以「旧侧行集（上下文+删除）」在期望位置（hunk 头 oldStart
  ///   叠加已应用块的净行数漂移）做精确匹配，失败则在 ±[_hunkFuzzWindow]
  ///   行内就近查找，再失败即保守跳过本块（不写坏其余块）；
  /// - 只按 '\n' 拆分/拼接，不改写行内容：字节级等于各接受 hunk 顺序
  ///   应用的结果（CRLF、无末行换行、空文件均原样保持）。
  static String applySelectedHunksForTest(
    String baseContent,
    List<DiffHunk> hunks,
    Set<int> acceptedIndexes,
  ) {
    if (hunks.isEmpty || acceptedIndexes.isEmpty) return baseContent;
    final picked =
        acceptedIndexes.where((i) => i >= 0 && i < hunks.length).toList()..sort();
    if (picked.isEmpty) return baseContent;
    final lines = baseContent.split('\n');
    // 已应用块的净行数变化：后续 hunk 的头行号是旧文件坐标，需叠加漂移。
    var drift = 0;
    for (final index in picked) {
      final hunk = hunks[index];
      final oldLines = hunk.oldLines;
      final newLines = hunk.newLines;
      // hunk 头 → 0 基下标；纯插入块（oldCount==0）插在 oldStart 之后。
      var expect = (hunk.oldCount == 0 ? hunk.oldStart : hunk.oldStart - 1) +
          drift;
      if (expect < 0) expect = 0;
      if (expect > lines.length) expect = lines.length;
      final at = _locateHunkBlock(lines, oldLines, expect);
      // 定位失败：保守跳过本块，继续处理后续块（不抛错到 UI 外）。
      if (at < 0) continue;
      lines.replaceRange(at, at + oldLines.length, newLines);
      drift += newLines.length - oldLines.length;
    }
    return lines.join('\n');
  }

  /// 在 [lines] 里定位 hunk 旧侧行集 [oldLines]：先按期望下标精确比对，
  /// 失败则在 ±窗口内就近查找；找不到返回 -1（调用方跳过该块）。
  /// 纯插入块（[oldLines] 为空）无锚可比，直接回期望下标（已由调用方钳制）。
  static int _locateHunkBlock(
    List<String> lines,
    List<String> oldLines,
    int expect,
  ) {
    if (oldLines.isEmpty) return expect;
    bool matchAt(int at) {
      if (at < 0 || at + oldLines.length > lines.length) return false;
      for (var k = 0; k < oldLines.length; k++) {
        if (lines[at + k] != oldLines[k]) return false;
      }
      return true;
    }

    if (matchAt(expect)) return expect;
    for (var d = 1; d <= _hunkFuzzWindow; d++) {
      if (matchAt(expect - d)) return expect - d;
      if (matchAt(expect + d)) return expect + d;
    }
    return -1;
  }

}

class CheckpointScope extends InheritedNotifier<CheckpointStore> {
  const CheckpointScope({
    super.key,
    required CheckpointStore store,
    required super.child,
  }) : super(notifier: store);

  static CheckpointStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<CheckpointScope>();
    assert(scope != null, 'CheckpointScope not found');
    return scope!.notifier!;
  }
}
