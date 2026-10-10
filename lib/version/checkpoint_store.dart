import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
class CheckpointInfo {
  CheckpointInfo({
    required this.id,
    required this.message,
    required this.createdAt,
    required this.kind,
    required this.files,
    this.chatId,
    // R3：记录时的 git 元信息（无仓库时全空），便于回退时核对外部 git 状态。
    this.gitBranch,
    this.gitCommit,
    this.gitDirty,
  });

  final String id;
  final String message;
  final DateTime createdAt;
  final String kind;
  final List<String> files;
  final String? chatId;
  final String? gitBranch;
  final String? gitCommit;
  final bool? gitDirty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'message': message,
    'createdAt': createdAt.toIso8601String(),
    'kind': kind,
    'files': files,
    if (chatId != null) 'chatId': chatId,
    if (gitBranch != null) 'gitBranch': gitBranch,
    if (gitCommit != null) 'gitCommit': gitCommit,
    if (gitDirty != null) 'gitDirty': gitDirty,
  };

  static CheckpointInfo fromJson(Map<String, dynamic> j) => CheckpointInfo(
    id: '${j['id']}',
    message: '${j['message'] ?? ''}',
    createdAt: DateTime.tryParse('${j['createdAt'] ?? ''}') ?? DateTime.now(),
    kind: '${j['kind'] ?? 'auto'}',
    files: ((j['files'] as List?) ?? []).map((e) => '$e').toList(),
    chatId: j['chatId'] as String?,
    gitBranch: j['gitBranch'] as String?,
    gitCommit: j['gitCommit'] as String?,
    gitDirty: j['gitDirty'] as bool?,
  );

  /// R7-GAP06 补丁说明规范校验（测试可见）——Conventional Commits 精简口径：
  /// `type: subject`（type限feat/fix/refactor/perf/test/docs/chore/revert，
  /// subject非空≤72字）。来源 https://aider.chat/HISTORY.html （采纳：
  /// message合规模板；不采纳：View Differences远端渲染，本地diff_view已有）。
  static bool isConventionalMessageForTest(String message) {
    final m = message.trim();
    if (m.isEmpty || m.length > 200) return false;
    final idx = m.indexOf(':');
    if (idx <= 0) return false;
    const types = {
      'feat',
      'fix',
      'refactor',
      'perf',
      'test',
      'docs',
      'chore',
      'revert',
    };
    if (!types.contains(m.substring(0, idx).trim())) return false;
    final subject = m.substring(idx + 1).trim();
    return subject.isNotEmpty && subject.length <= 72;
  }
}

/// R3：读取工作区 git 元信息（分支/commit/是否有未提交改动）。
/// 非 git 仓库或 git 不可用时返回空记录，不抛错、不阻塞 checkpoint。
class GitSnapshot {
  const GitSnapshot({this.branch, this.commit, this.dirty});

  final String? branch;
  final String? commit;
  final bool? dirty;

  bool get hasRepo => branch != null || commit != null;

  static Future<GitSnapshot> capture(String rootPath) async {
    try {
      final branchRes = await Process.run('git', [
        '-C',
        rootPath,
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ]).timeout(const Duration(seconds: 3));
      if (branchRes.exitCode != 0) return const GitSnapshot();
      final commitRes = await Process.run('git', [
        '-C',
        rootPath,
        'rev-parse',
        '--short',
        'HEAD',
      ]).timeout(const Duration(seconds: 3));
      final statusRes = await Process.run('git', [
        '-C',
        rootPath,
        'status',
        '--porcelain',
      ]).timeout(const Duration(seconds: 5));
      final branch = '${branchRes.stdout ?? ''}'.trim();
      final commit = '${commitRes.stdout ?? ''}'.trim();
      final dirty = statusRes.exitCode == 0
          ? '${statusRes.stdout ?? ''}'.trim().isNotEmpty
          : null;
      return GitSnapshot(
        branch: branch.isEmpty ? null : branch,
        commit: commit.isEmpty ? null : commit,
        dirty: dirty,
      );
    } catch (_) {
      return const GitSnapshot();
    }
  }
}

class FileChange {
  FileChange({
    required this.path,
    required this.type,
    this.diff = '',
    this.hash,
    this.binary = false,
  });

  final String path;

  /// added | modified | deleted
  final String type;
  final String diff;
  final String? hash;
  final bool binary;

  Map<String, dynamic> toJson() => {
    'path': path,
    'type': type,
    'diff': diff,
    if (hash != null) 'hash': hash,
    if (binary) 'binary': true,
  };

  static FileChange fromJson(Map<String, dynamic> j) {
    // 第11轮R2-1：脏数据fail-closed——此前'${j['path']}'把缺失转“null”
    // 字符串，redo.json被篡改后脏条直接入栈写区外。现空path/非法type抛错，
    // _loadRedoStack逐条try跳过脏条不进栈（与_isSafeVersionId同口径）。
    final path = '${j['path'] ?? ''}';
    final type = '${j['type'] ?? ''}';
    if (path.isEmpty ||
        type != 'added' && type != 'modified' && type != 'deleted') {
      throw StateError('非法版本差量');
    }
    return FileChange(
      path: path,
      type: type,
      diff: '${j['diff'] ?? ''}',
      hash: j['hash'] as String?,
      binary: j['binary'] == true,
    );
  }
}

class CheckpointStore extends ChangeNotifier {
  static bool Function(String rel)? debugFailBeforeRename;
  String? _rootPath;
  Directory? _versionsDir;
  List<CheckpointInfo> _checkpoints = [];
  // R2-CK1：manifest成功加载标记——主备双坏时内存为空但磁盘tree/diff仍在，
  // 此时_gcOrphanArtifacts以live={}删光全库。未成功加载即不删。
  bool _manifestLoaded = false;
  final Map<String, List<FileChange>> _diffCache = {};
  final Map<String, Map<String, String>> _treeCache = {};
  // R9-缓存有界：长会话翻版本即 _diffCache/_treeCache 只增不收，
  // 此前无界。现超 64 条丢最旧，与 WorkspaceSearch 64 上限同口径。
  void _boundVersionCaches() {
    while (_diffCache.length > 64) {
      _diffCache.remove(_diffCache.keys.first);
    }
    while (_treeCache.length > 64) {
      _treeCache.remove(_treeCache.keys.first);
    }
  }

  bool _busy = false;
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

  String? get rootPath => _rootPath;
  List<CheckpointInfo> get checkpoints => List.unmodifiable(_checkpoints);
  bool get busy => _busy;
  bool get canRedo => _redoPatches.isNotEmpty;
  List<String> get redoLabels => List.unmodifiable(_redoLabels);

  /// 短随机 hash（12 hex），保证 manifest 内唯一。
  /// 第6轮收敛：时间戳兜底同样判重——此前32连撞后兜底直接返回，
  /// 极端碰撞下可与现存 id 重复致 manifest 互盖。现兜底同样查 existing，
  /// 仍撞则拼随机后缀。对齐 Roo Code checkpoint 可恢复口径。
  String _newVersionId() {
    final existing = _checkpoints.map((e) => e.id).toSet();
    for (var i = 0; i < 32; i++) {
      final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
      final id = sha1.convert(bytes).toString().substring(0, 12);
      if (!existing.contains(id)) return id;
    }
    // 极端碰撞：时间戳兜底同样判重，仍撞拼随机后缀。
    for (var i = 0; i < 8; i++) {
      final stamp =
          '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}-$i';
      final id = sha1.convert(utf8.encode(stamp)).toString().substring(0, 12);
      if (!existing.contains(id)) return id;
    }
    return sha1
        .convert(
          utf8.encode(
            '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 64)}',
          ),
        )
        .toString()
        .substring(0, 12);
  }

  Future<void> bindProject(String? rootPath) async {
    // D7-4：在途 restore/checkpoint 时拒绝切项目/清库。否则 _commitOps 等
    // 提交路径会用新 _rootPath 执行旧 ops，把旧项目的恢复内容写穿到新项目。
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    _rootPath = rootPath;
    _checkpoints = [];
    _diffCache.clear();
    _treeCache.clear();
    _redoPatches.clear();
    _redoLabels.clear();
    if (rootPath == null) {
      _versionsDir = null;
      notifyListeners();
      return;
    }
    _versionsDir = Directory(p.join(rootPath, '.my_ide', 'versions'));
    try {
      await _ensureDir(_versionsDir!);
      await _ensureDir(
        Directory(p.join(_versionsDir!.path, 'objects', 'blobs')),
      );
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'trees')));
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'diffs')));
      await _ensureDir(Directory(p.join(_versionsDir!.path, 'snapshots')));
    } catch (_) {
      // 项目目录权限不足时仍允许使用（对话落盘也容错），仅清空内存缓存。
      _versionsDir = null;
    }
    await _loadManifest();
    await _loadRedoStack();
    // R3-03/04：提交事务 journal 重放 + 孤儿清理 + 多窗口 manifest 互斥预检。
    await _replayCommitJournal();
    await _gcOrphanArtifacts();
    notifyListeners();
  }

  Future<void> _ensureDir(Directory dir) async {
    try {
      await dir.create(recursive: true);
    } catch (_) {
      if (!await dir.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await dir.create(recursive: true);
      }
    }
  }

  /// Redo 栈持久化：重启不再丢，bindProject 时恢复。
  /// 此前纯内存，重启后 Restore 保险直接没了。
  Future<void> _saveRedoStack() async {
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      await _writeFileAtomic(
        File(p.join(versions.path, 'redo.json')),
        jsonEncode({
          'labels': _redoLabels,
          'patches': _redoPatches
              .map((patch) => patch.map((e) => e.toJson()).toList())
              .toList(),
        }),
      );
    } catch (_) {}
  }

  Future<void> _loadRedoStack() async {
    _redoPatches.clear();
    _redoLabels.clear();
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      final file = File(p.join(versions.path, 'redo.json'));
      if (!await file.exists()) return;
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final labels = (data['labels'] as List?) ?? const [];
      final patches = (data['patches'] as List?) ?? const [];
      for (var i = 0; i < patches.length && i < 20; i++) {
        final raw = patches[i];
        if (raw is! List) continue;
        // 第11轮R2-1：脏条逐条跳过——fromJson现抛错，全批map即整批丢，
        // 合法条被单脏条连带。现逐条try，脏条跳过不进栈。
        final items = <FileChange>[];
        for (final e in raw.whereType<Map>()) {
          try {
            items.add(FileChange.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
        _redoPatches.add(items);
        _redoLabels.add(i < labels.length ? '${labels[i]}' : 'Redo');
      }
    } catch (_) {}
  }

  /// R3-03：提交事务 journal——tree/diff/manifest 三步落盘前先记 journal，
  /// 成功后清 journal；崩溃重启经 bindProject 重放：journal 记的 id 若
  /// tree+diff 已齐则补 manifest 收尾，否则删孤儿 tree/diff 不留半提交。
  Future<void> _writeCommitJournal(String id, String? prevId) async {
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      await _writeFileAtomic(
        File(p.join(versions.path, 'commit.json')),
        jsonEncode({
          'id': id,
          'prevId': prevId,
          'at': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  Future<void> _clearCommitJournal() async {
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      final f = File(p.join(versions.path, 'commit.json'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _replayCommitJournal() async {
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      final f = File(p.join(versions.path, 'commit.json'));
      if (!await f.exists()) return;
      final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final id = '${data['id'] ?? ''}';
      if (!_isSafeVersionId(id)) {
        await _clearCommitJournal();
        return;
      }
      final treeOk = await File(
        p.join(versions.path, 'trees', '$id.json'),
      ).exists();
      final diffOk = await File(
        p.join(versions.path, 'diffs', '$id.json'),
      ).exists();
      final inManifest = _checkpoints.any((e) => e.id == id);
      if (treeOk && diffOk && !inManifest) {
        try {
          final tree = await _loadTree(id);
          final changes = await changesOf(id);
          _checkpoints.insert(
            0,
            CheckpointInfo(
              id: id,
              message: 'crash-recovered',
              createdAt: DateTime.now(),
              kind: 'auto-backup',
              files: changes.isEmpty
                  ? tree.keys.toList()
                  : changes.map((e) => e.path).toList(),
            ),
          );
          // R2-CK3：manifest保存成功才清journal——此前内层吞错后
          // 外层无条件清，磁盘满/只读时journal丢失无法再收尾。
          await _saveManifest();
          _manifestLoaded = true;
        } catch (_) {
          return;
        }
      } else if (!treeOk || !diffOk) {
        try {
          final t = File(p.join(versions.path, 'trees', '$id.json'));
          if (await t.exists()) await t.delete();
        } catch (_) {}
        try {
          final d = File(p.join(versions.path, 'diffs', '$id.json'));
          if (await d.exists()) await d.delete();
        } catch (_) {}
      }
    } catch (_) {}
    await _clearCommitJournal();
  }

  /// R3-03：孤儿产物清理——manifest 未引用但落盘的 tree/diff 即上次崩溃
  /// 半提交残留，bindProject 时清掉不留垃圾。
  /// R2-CK1：manifest未成功加载（主备双坏）时live={}会删光全库，
  /// 此时直接返回不删。
  Future<void> _gcOrphanArtifacts() async {
    final versions = _versionsDir;
    if (versions == null) return;
    if (!_manifestLoaded) return;
    try {
      final live = _checkpoints.map((e) => e.id).toSet();
      for (final sub in const ['trees', 'diffs']) {
        final dir = Directory(p.join(versions.path, sub));
        if (!await dir.exists()) continue;
        await for (final e in dir.list(followLinks: false)) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (!name.endsWith('.json')) continue;
          final id = name.substring(0, name.length - 5);
          if (!_isSafeVersionId(id) || !live.contains(id)) {
            try {
              await e.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  /// R3-04：多窗口 manifest 互斥——保存前重读磁盘 manifest，与内存合并后
  /// 再写回，避免 AB 双窗口同项目并发 checkpoint 后写赢丢节点。
  Future<void> _mergeManifestBeforeSave() async {
    final versions = _versionsDir;
    if (versions == null) return;
    try {
      final manifest = File(p.join(versions.path, 'manifest.json'));
      if (!await manifest.exists()) return;
      final data =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      final disk = ((data['checkpoints'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => CheckpointInfo.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => _isSafeVersionId(e.id))
          .toList();
      final mem = _checkpoints.map((e) => e.id).toSet();
      var changed = false;
      for (final cp in disk) {
        if (mem.add(cp.id)) {
          _checkpoints.add(cp);
          changed = true;
        }
      }
      if (changed) {
        // R8-06：同毫秒按id二次排序——此前仅createdAt，同毫秒/时钟回拨即错乱抖动。
        _checkpoints.sort((a, b) {
          final c = b.createdAt.compareTo(a.createdAt);
          return c != 0 ? c : a.id.compareTo(b.id);
        });
      }
    } catch (_) {}
  }

  Future<void> _loadManifest() async {
    // D7-1：bindProject 目录创建失败会先把 _versionsDir 置 null 再走到这里，
    // version_panel refresh 亦可达；此前 `_versionsDir!` 直接空指针。
    final versions = _versionsDir;
    if (versions == null) return;
    final manifest = File(p.join(versions.path, 'manifest.json'));
    if (!await manifest.exists()) {
      _checkpoints = [];
      // 无文件即空库：GC可正常清理孤儿（无磁盘tree/diff需保护）。
      _manifestLoaded = true;
      // manifest 缺失时用影子仓补骨架（新库无影子即保持空）。
      await _rebuildCheckpointsFromShadows(versions);
      return;
    }
    // 主文件失败时读备份；都失败则保留内存历史，不静默清空。
    final candidates = [
      manifest,
      File(p.join(versions.path, 'manifest.json.bak')),
    ];
    for (final file in candidates) {
      try {
        if (!await file.exists()) continue;
        final data =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final loaded = ((data['checkpoints'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => CheckpointInfo.fromJson(Map<String, dynamic>.from(e)))
            // manifest 毒化过滤：crafted id（如 ../../x）不进内存，
            // 否则后续 _relinkDiffs/dropVersions 用 cp.id 拼路径穿越写盘外。
            .where((e) => _isSafeVersionId(e.id))
            .toList();
        // manifest 数组顺序即时间线（新→旧），不再按 createdAt 重排，
        // 避免同毫秒/时钟回拨错乱。
        _checkpoints = loaded;
        _manifestLoaded = true;
        return;
      } catch (_) {
        continue;
      }
    }
    // 主备都坏：保留内存历史，等待下次成功保存覆盖，不清空。
    // 影子恢复：主备解析都失败时，用影子仓重建骨架保证版本链不丢。
    await _rebuildCheckpointsFromShadows(versions);
  }

  /// 影子恢复：manifest 缺失或主备解析失败时，用影子仓重建骨架。
  /// 只在当前 _checkpoints 为空时补（不覆盖主备已读出的节点），
  /// 骨架 message='影子恢复'、kind='auto-backup'，files 取影子 tree 的 key。
  Future<void> _rebuildCheckpointsFromShadows(Directory versions) async {
    try {
      if (_checkpoints.isNotEmpty) return;
      final shadows = await ShadowStore.loadAllShadows(versions.path);
      if (shadows.isEmpty) return;
      final ids = shadows.keys.where(_isSafeVersionId).toList()..sort();
      _checkpoints = [
        for (final id in ids.reversed)
          CheckpointInfo(
            id: id,
            message: '影子恢复',
            createdAt: DateTime.now(),
            kind: 'auto-backup',
            files: (shadows[id]!.keys.toList()..sort()),
          ),
      ];
      _manifestLoaded = true;
    } catch (_) {}
  }

  /// 原子保存：tmp 写盘 + flush + rename，旧 manifest 留 .bak。
  /// 先写 `.new` 再 rename 成 `.bak`：copy 非原子，崩溃可双坏；
  /// `.new` 写坏只影响备份链，主文件仍可用。
  Future<void> _saveManifest() async {
    final versions = _versionsDir;
    if (versions == null) return;
    final manifest = File(p.join(versions.path, 'manifest.json'));
    final payload = jsonEncode({
      'format': 'cas-v2',
      'checkpoints': _checkpoints.map((e) => e.toJson()).toList(),
    });
    // 先把旧 manifest 拷到 .bak，再原子覆盖主文件，主备双读才有意义。
    // R2-A1 备份侧车唯一名：固定 .bak.new 并发双写互盖，此处同样唯一 nonce。
    try {
      final bak = File(p.join(versions.path, 'manifest.json.bak'));
      if (await manifest.exists()) {
        final bakNonce =
            '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}';
        final bakNew = File(
          p.join(versions.path, 'manifest.json.bak.$bakNonce.new'),
        );
        await manifest.copy(bakNew.path);
        try {
          await bakNew.rename(bak.path);
        } catch (_) {
          await bakNew.copy(bak.path);
          try {
            await bakNew.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    await _writeFileAtomic(manifest, payload);
  }

  /// 通用原子写：唯一 tmp+flush+rename，崩溃不留半写文件。
  /// trees/diffs/blob/session 统一走这里，不再直接 writeAsString。
  /// 固定 `.tmp` 名此前并发写同目标会互盖侧车，改唯一名。
  /// nonce 用 Random.secure（_rng）：micros+hashCode 仅 16bit 非稳定。
  Future<void> _writeFileAtomic(File target, String content) async {
    await target.parent.create(recursive: true);
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${target.path}.$nonce.tmp');
    try {
      await tmp.writeAsString(content, flush: true);
      try {
        await tmp.rename(target.path);
      } catch (_) {
        // Windows 占有时 rename 失败：回退直写（至少保证内容落地）。
        await target.writeAsString(content, flush: true);
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 二进制原子写：blob/tree 二进制统一走这里。
  Future<void> _writeBytesAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}';
    final tmp = File('${target.path}.$nonce.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      try {
        await tmp.rename(target.path);
      } catch (_) {
        await target.writeAsBytes(bytes, flush: true);
      }
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 时间线旧→新：以 manifest 数组顺序（新→旧）反转得到，不依赖 createdAt 排序。
  List<CheckpointInfo> _orderedOldToNew() =>
      _checkpoints.reversed.toList(growable: false);

  Future<void> refresh() async {
    await _loadManifest();
    notifyListeners();
  }

  File _blobFile(String hash) {
    // B8：hash 必须为 hex，否则 crafted tree/diff 可经 ../../ 穿越到版本库外。
    if (!_isHexHash(hash)) throw StateError('非法 blob hash');
    final versions = _versionsDir!;
    final prefix = hash.length >= 2 ? hash.substring(0, 2) : '00';
    final rest = hash.length >= 2 ? hash.substring(2) : hash;
    return File(p.join(versions.path, 'objects', 'blobs', prefix, rest));
  }

  static bool _isHexHash(String hash) =>
      hash.isNotEmpty &&
      hash.length <= 128 &&
      RegExp(r'^[0-9a-f]+$').hasMatch(hash);

  /// 版本 id 门禁：12 hex（兼容旧 snapshots 目录名），防 `../` 穿越。
  static bool _isSafeVersionId(String id) =>
      id.isNotEmpty && id.length <= 64 && RegExp(r'^[0-9a-f]+$').hasMatch(id);

  Future<void> _writeBlob(String hash, List<int> bytes) async {
    final file = _blobFile(hash);
    if (await file.exists()) return;
    await _writeBytesAtomic(file, bytes);
  }

  Future<bool> _blobExists(String hash) async {
    try {
      return await _blobFile(hash).exists();
    } catch (_) {
      return false;
    }
  }

  Future<List<int>?> _readBlobBytes(String hash) async {
    final file = _blobFile(hash);
    if (!await file.exists()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  String? _decodeText(List<int> bytes) {
    if (bytes.isEmpty) return '';
    var nullCount = 0;
    var controlCount = 0;
    for (final b in bytes) {
      if (b == 0) {
        nullCount++;
        continue;
      }
      final allowed = b == 9 || b == 10 || b == 13;
      if (b < 32 && !allowed) controlCount++;
    }
    if (nullCount > bytes.length * 0.01) return null;
    if (controlCount > bytes.length * 0.02) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  bool _isTempSidecar(String rel) {
    final base = p.basename(rel);
    // R4-05：commit.json 同样排除——事务 journal 属版本库元数据，此前落快照
    // 致每轮版本 diff 含 commit.json 噪音。正常文件名含该段概率极低。
    if (base == 'commit.json') return true;
    // 唯一侧车名形如 `a.txt.<micros>.myide-new` / 恢复侧 `*.myide-restore` /
    // `f.<micros>-<h>.tmp`：后缀匹配会漏掉中间段，改含段匹配；正常文件名含该段概率极低。
    // 落盘侧车形如 `f.<micros>-<h>.tmp` / `.myide-new`：后缀兜底，
    // 避免并发两写的侧车污染 touchedFiles/快照。
    return base.contains('.myide-new') ||
        base.contains('.myide-restore') ||
        base.endsWith('.tmp');
  }

  String _stagingPath(String abs) =>
      '$abs.${DateTime.now().microsecondsSinceEpoch}-${_rng.nextInt(1 << 32).toRadixString(36)}.myide-restore';

  Future<void> _writeTree(String id, Map<String, String> files) async {
    if (!_isSafeVersionId(id)) throw StateError('非法版本 id');
    final versions = _versionsDir!;
    final file = File(p.join(versions.path, 'trees', '$id.json'));
    final sorted = Map.fromEntries(
      files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    await _writeFileAtomic(file, jsonEncode({'id': id, 'files': sorted}));
    _treeCache[id] = Map<String, String>.from(sorted);
    _boundVersionCaches();
    // 影子仓：落 tree 成功后顺手写本地第二副本，失败吞错不阻塞。
    unawaited(ShadowStore.writeShadow(versions.path, id, sorted));
  }

  /// 记录一次 checkpoint：内容寻址写 blob，tree 只记 path→hash。
  ///
  /// kind 约定：
  /// - `user-edit`：用户编辑（下一轮发送前落盘）
  /// - `ai-edit` / `chat`：一轮 AI 对话结束时的唯一节点
  /// 不再写 chat-before 空节点；一轮对话最多一个版本。
  Future<CheckpointInfo?> checkpoint({
    required String message,
    String kind = 'auto',
    String? chatId,
    bool allowEmpty = false,
  }) async {
    final root = _rootPath;
    final versions = _versionsDir;
    if (root == null || versions == null) return null;
    // 4.2 并发排队替代抛错：_busy 时等待前一个 checkpoint 完成（最多 30s），
    // 此前直接抛错，AI 单步与手动版本并发必掉一端节点。
    if (_busy) {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (_busy && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_busy) {
        throw StateError('版本操作进行中，请稍后再试');
      }
    }
    _busy = true;
    notifyListeners();
    try {
      final id = _newVersionId();
      final currentFiles = await _captureWorkspace(root);
      final prevId = _checkpoints.isEmpty ? null : _checkpoints.first.id;
      final prevFiles = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);
      // 大文件直通保留：_captureWorkspace 跳过 >2MB 文件（防内存爆），
      // 此前缺失即判 deleted，下次 checkpoint 记删除，restore 再覆盖/删除用户大文件。
      // 现盘上仍存在且超限即沿用旧 hash（untracked，不记 deleted、不记 modified）。
      for (final key in prevFiles.keys) {
        if (currentFiles.containsKey(key)) continue;
        try {
          final f = File(p.join(root, key));
          if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
            currentFiles[key] = prevFiles[key]!;
          }
        } catch (_) {}
      }

      var changes = _diffTrees(prevFiles, currentFiles);
      // 默认无变化不记节点；user-edit / ai-edit 有真实 diff 才落盘。
      final keepEmpty = allowEmpty || kind == 'manual';
      if (changes.isEmpty && !keepEmpty) {
        return null;
      }

      await _writeTree(id, currentFiles);
      changes = await _materializeDiffs(
        changes: changes,
        prevFiles: prevFiles,
        currentFiles: currentFiles,
        prevId: prevId,
        currentFromWorkspace: true,
      );

      final diffFile = File(p.join(versions.path, 'diffs', '$id.json'));
      // R3-03：先记 journal 再落 tree/diff/manifest，崩溃可重放收尾或清孤儿。
      // R2-CK2注：tree落盘早于journal是既有顺序（tree需先算diff链），
      // 崩在tree/journal之间留孤儿tree由_gcOrphanArtifacts清，不静默丢节点。
      await _writeCommitJournal(id, prevId);
      await _writeFileAtomic(
        diffFile,
        jsonEncode({
          'id': id,
          'prevId': prevId,
          'changes': changes.map((e) => e.toJson()).toList(),
        }),
      );
      _diffCache[id] = changes;
      _boundVersionCaches();

      // R3：顺手记录 git 元信息（失败/无仓库则全空，不阻塞落盘）。
      final git = await GitSnapshot.capture(root);
      final info = CheckpointInfo(
        id: id,
        message: message,
        createdAt: DateTime.now(),
        kind: kind,
        files: changes.map((e) => e.path).toList(),
        chatId: chatId,
        gitBranch: git.branch,
        gitCommit: git.commit,
        gitDirty: git.dirty,
      );
      _checkpoints.insert(0, info);
      // R3-04：保存前合并磁盘 manifest，多窗口并发不丢节点。
      await _mergeManifestBeforeSave();
      if (!_checkpoints.any((e) => e.id == id)) _checkpoints.insert(0, info);
      await _saveManifest();
      await _clearCommitJournal();
      // git 锚点：成功落盘后 fire-and-forget 记命名 commit，不阻塞返回。
      try {
        unawaited(GitAnchor.maybeAnchorCommit(root, info.message));
      } catch (_) {}
      // worktree 隔离：变化文件数达阈值且开启时，fire-and-forget 建备份分支。
      unawaited(() async {
        try {
          final threshold = await GitWorktree.prefsThreshold();
          if (changes.length >= threshold &&
              await GitWorktree.prefsAutoIsolate()) {
            await GitWorktree.ensureBackupBranch(root, 'pre-checkpoint');
          }
        } catch (_) {}
      }());
      // 4.4 版本上限：只保留最近 100 个节点，超量删最旧的 ai 单步节点，
      // manual/auto-backup 保留。无上限曾导致每 tool 一节点无限膨胀。
      await _enforceVersionCap();
      notifyListeners();
      // 遥测：checkpoint 成功后记一条（仅数量，不记路径原文）。
      try {
        await Telemetry.record('checkpoint', {
          'kind': kind,
          'files': info.files.length,
        });
      } catch (_) {}
      return info;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 版本数上限 GC：超限时只删 ai-edit-step，且每个 chatId 至少保留 1 个；
  /// manual/auto-backup/user-edit/ai-edit 永不淘汰。上限读 prefs versionMaxNodes（默认100，20~500）。
  /// 不可淘汰时直接返回：此前静默超限，多手动/多会话可永久超限，
  /// 此处不再假装回收，调用方靠 manifest 长度可见。
  Future<void> _enforceVersionCap({int? maxVersions}) async {
    final max = maxVersions ?? await versionMaxNodes();
    if (_checkpoints.length <= max) return;
    final ordered = _orderedOldToNew();
    // 每个 chatId 至少保留 1 个：先统计各 chat 最新节点（时间线最靠后=数组最靠前）。
    final keepLatestByChat = <String>{};
    final seenChat = <String>{};
    for (final cp in _checkpoints) {
      final chat = cp.chatId;
      if (chat == null || chat.isEmpty) continue;
      if (seenChat.add(chat)) keepLatestByChat.add(cp.id);
    }
    var need = _checkpoints.length - max;
    final evictable = <String>{};
    // 从最旧往新扫描，只淘汰 ai-edit-step，且跳过各 chat 最新保留节点。
    for (final cp in ordered) {
      if (need <= 0) break;
      if (cp.kind != 'ai-edit-step') continue;
      if (keepLatestByChat.contains(cp.id)) continue;
      evictable.add(cp.id);
      need--;
    }
    if (evictable.isEmpty) return;
    // checkpoint() 持 _busy 锁内调用：借位执行，内层 dropVersions 靠
    // _dropReentrancy 通过 _busy 守卫（否则直接抛错被吞，上限永不生效）。
    final borrowed = _busy;
    if (borrowed) _dropReentrancy++;
    try {
      await dropVersions(evictable);
    } catch (_) {
    } finally {
      if (borrowed) _dropReentrancy--;
    }
  }

  /// 版本上限：prefs versionMaxNodes，默认 100，钳制 20~500。
  static Future<int> versionMaxNodes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt('versionMaxNodes') ?? 100).clamp(20, 500);
    } catch (_) {
      return 100;
    }
  }

  Future<List<FileChange>> changesOf(String id) async {
    if (!_isSafeVersionId(id)) return [];
    // D7-5：缓存命中的内部 List 不得外泄（调用方 mutate 会污染差量缓存）。
    if (_diffCache.containsKey(id)) return List.unmodifiable(_diffCache[id]!);
    final versions = _versionsDir;
    if (versions == null) return [];
    final file = File(p.join(versions.path, 'diffs', '$id.json'));
    if (!await file.exists()) return [];
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final changes = ((data['changes'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => FileChange.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _diffCache[id] = changes;
      _boundVersionCaches();
      return List.unmodifiable(changes);
    } catch (_) {
      return [];
    }
  }

  Future<String> diffTextOf(String id) async {
    final changes = await changesOf(id);
    if (changes.isEmpty) return '（无文件变化）';
    final buf = StringBuffer();
    for (final c in changes) {
      buf.writeln('diff -- ${c.type} ${c.path}');
      if (c.diff.isNotEmpty) {
        buf.writeln(c.diff);
      } else {
        // 旧占位头：即时算
        final live = await lineDiff(id, c.path);
        if (live.isNotEmpty) buf.writeln(live);
      }
      buf.writeln();
    }
    return buf.toString();
  }

  /// 取某版本某文件的文本：差量链重建；旧 blob / snapshots 仅兼容。
  Future<String?> fileContentAt(String id, String relPath) async {
    final versions = _versionsDir;
    final root = _rootPath;
    // B8+门禁前置：非法 id/越界 rel 不得触发 _loadTree/diff 重建，
    // 否则 crafted 输入先走全链 IO 再被拒，且失败路径不一致。
    if (versions == null ||
        root == null ||
        !_isSafeRestoreRel(root, relPath) ||
        !_isSafeVersionId(id)) {
      return null;
    }
    final payload = await _filePayload(
      path: relPath,
      hash: (await _loadTree(id))[relPath],
      versionId: id,
    );
    if (payload.binary) return null;
    if (payload.text != null) return payload.text;
    final file = File(p.join(versions.path, 'snapshots', id, relPath));
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
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

  Future<Map<String, String>> _captureWorkspace(String root) async {
    final result = <String, String>{};
    final rootDir = Directory(root);
    await for (final entity in rootDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: root);
      if (_isSnapshotSkipped(rel)) continue;
      if (p.basename(rel) == '.DS_Store') continue;
      if (_isTempSidecar(rel)) continue;
      String? hash;
      try {
        // 先判大小再读：此前 readAsBytes 后才判 2MB，大文件照样进内存。
        // 第2轮R2-1：读后复检+链接复检——length→read间隙外部追加到GB即OOM，
        // 枚举后file→symlink替换即跟随读出区外。读后字节复检超限即跳过，
        // 读前链接复检命中即跳过（枚举到读之间换链）。
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          continue;
        }
        final size = await entity.length();
        if (size > 2 * 1024 * 1024) continue;
        final bytes = await entity.readAsBytes();
        if (bytes.length > 2 * 1024 * 1024) continue;
        hash = sha1.convert(bytes).toString();
        if (_decodeText(bytes) == null) {
          try {
            await _writeBlob(hash, bytes);
          } catch (_) {
            // blob 落盘失败仍保留 hash：后续读取走 missing 报错路径，
            // 不让文件从快照里静默消失导致差量算错。
          }
        }
        result[rel] = hash;
      } catch (_) {
        // 读失败才跳过；hash 已算出时上面已记录。
        if (hash != null && !result.containsKey(rel)) {
          result[rel] = hash;
        }
      }
    }
    return result;
  }

  Future<_FilePayload> _filePayload({
    required String path,
    required String? hash,
    String? versionId,
    bool fromWorkspace = false,
    String? knownText,
  }) async {
    if (knownText != null) {
      return _FilePayload(text: knownText, binary: false);
    }
    if (hash == null) {
      return const _FilePayload(text: '', binary: false);
    }
    if (fromWorkspace && _rootPath != null) {
      // 投毒 tree 防护：crafted relPath（如 ../../etc/passwd）不得读出区外，
      // 此前直拼 root+path 把区外内容读进 redo/diff 持久化。
      if (!_isSafeRestoreRel(_rootPath!, path)) {
        return const _FilePayload(text: '', binary: false);
      }
      final file = File(p.join(_rootPath!, path));
      if (!await file.exists()) {
        return const _FilePayload(text: '', binary: false);
      }
      try {
        // R7-A1 恢复侧同样2MB门禁：_captureWorkspace快照侧有2MB上限，
        // 恢复侧此前直读，大文件恢复即OOM。现先length预检超限拒读。
        try {
          if (await file.length() > 2 * 1024 * 1024) {
            return const _FilePayload(text: '', binary: false);
          }
        } catch (_) {}
        final bytes = await file.readAsBytes();
        final text = _decodeText(bytes);
        if (text == null) {
          return _FilePayload(binary: true, bytes: bytes);
        }
        return _FilePayload(text: text, binary: false, bytes: bytes);
      } catch (_) {
        return const _FilePayload(binary: false);
      }
    }
    if (await _blobExists(hash)) {
      final bytes = await _readBlobBytes(hash);
      if (bytes != null) {
        final text = _decodeText(bytes);
        if (text == null) {
          return _FilePayload(binary: true, bytes: bytes);
        }
        return _FilePayload(text: text, binary: false, bytes: bytes);
      }
    }
    final reconstructed = await _textForHash(path, hash, hintId: versionId);
    if (reconstructed != null) {
      return _FilePayload(text: reconstructed, binary: false);
    }
    return const _FilePayload(binary: false);
  }

  Future<String?> _textForHash(
    String path,
    String hash, {
    String? hintId,
  }) async {
    final ordered = _orderedOldToNew();
    var hint = hintId == null
        ? ordered.length - 1
        : ordered.indexWhere((e) => e.id == hintId);
    if (hint < 0) hint = ordered.length - 1;
    for (var i = hint; i >= 0; i--) {
      final tree = await _loadTree(ordered[i].id);
      if (tree[path] != hash) continue;
      return _reconstructText(ordered[i].id, path);
    }
    return null;
  }

  /// 从最旧版本正向套用 unified diff，重建文本。二进制返回 null。
  Future<String?> _reconstructText(String id, String relPath) async {
    final ordered = _orderedOldToNew();
    final end = ordered.indexWhere((e) => e.id == id);
    if (end < 0) return null;
    // R9-A3 重建链回溯上限50：百轮会话此前全链changesOf即IO爆炸。
    // 近50轮未命中即放弃（返回null走missing路径，不产垃圾错文）。
    final start = end - 50 < 0 ? 0 : end - 50;
    String? content;
    var present = false;
    for (var i = start; i <= end; i++) {
      final changes = await changesOf(ordered[i].id);
      FileChange? hit;
      for (final c in changes) {
        if (c.path == relPath) {
          hit = c;
          break;
        }
      }
      if (hit == null) continue;
      if (hit.binary) return null;
      if (hit.type == 'deleted') {
        present = false;
        content = null;
        continue;
      }
      try {
        // R3-V1：重建开校验——此前硬套漂移diff产垃圾错文误导回滚。
        // added不校验（全量新内容无上下文可验，与redo路径同口径），
        // 否则创世added重建即抛错（D3回归）。
        // R3-V1e：校验失败允许形态迁移——relink删中间节点后，
        // 旧差量形状兼容但上下文对不上（如base→user链），硬返null会
        // 把current判空致备份diff坏掉（D3：backup diff丢+行）。
        // 现先校验，StateError则无校验再套一次；形态兼容即自愈，
        // 结构性失败（binary/截断）仍抛错返null。
        try {
          content = _applyUnifiedDiff(
            content ?? '',
            hit.diff,
            validateContext: hit.type != 'added',
          );
        } on StateError {
          content = _applyUnifiedDiff(content ?? '', hit.diff);
        }
        present = true;
      } catch (_) {
        return null;
      }
    }
    return present ? content : null;
  }

  /// [validateContext] 为 true 时校验上下文/删除行与当前内容一致，
  /// 防止把旧基线的差量硬套到已漂移的文件上（Redo 路径必须开启）。
  String _applyUnifiedDiff(
    String oldText,
    String diff, {
    bool validateContext = false,
  }) {
    if (diff.isEmpty) return oldText;
    if (diff.startsWith('@@ binary') || diff.contains('\n@@ binary')) {
      throw StateError('binary diff cannot apply as text');
    }
    final oldLines = oldText.split('\n');
    final out = <String>[];
    var oldIndex = 0;
    final lines = diff.split('\n');
    var i = 0;
    // R3-V1b：跳过 unified diff 文件头 `--- a/…` / `+++ b/…`——
    // 此前头行 `--- a/path` 被误判为删除行（`-` 前缀）、`+++ b/path`
    // 被误判为新增行；不开校验时重建多出垃圾行，开校验即误抛错
    // 致合法链重建返 null（D3 回归：auto-backup 内容读不出）。
    // 只跳过紧随开头的标准头行，内容行 `-`/`+` 不受影响。
    if (i < lines.length && lines[i].startsWith('--- ')) i++;
    if (i < lines.length && lines[i].startsWith('+++ ')) i++;
    while (i < lines.length) {
      final line = lines[i];
      if (line.startsWith('@@ ')) {
        final match = RegExp(
          r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
        ).firstMatch(line);
        if (match == null) {
          i++;
          continue;
        }
        final oldStart = int.parse(match.group(1)!);
        final target = oldStart <= 1 ? 0 : oldStart - 1;
        while (oldIndex < target && oldIndex < oldLines.length) {
          out.add(oldLines[oldIndex]);
          oldIndex++;
        }
        i++;
        while (i < lines.length && !lines[i].startsWith('@@ ')) {
          final l = lines[i];
          if (l.startsWith('…')) {
            throw StateError('truncated diff');
          }
          if (l.startsWith('+')) {
            out.add(l.substring(1));
          } else if (l.startsWith('-')) {
            if (validateContext) {
              _expectLine(oldLines, oldIndex, l.substring(1));
            }
            oldIndex++;
          } else if (l.startsWith(' ')) {
            if (validateContext) {
              _expectLine(oldLines, oldIndex, l.substring(1));
            }
            out.add(l.substring(1));
            oldIndex++;
          }
          i++;
        }
        continue;
      }
      i++;
    }
    while (oldIndex < oldLines.length) {
      out.add(oldLines[oldIndex]);
      oldIndex++;
    }
    return out.join('\n');
  }

  void _expectLine(List<String> lines, int index, String expected) {
    // R3-V1c：越界按空行比对——空文本split得['']，生成器对幽灵空行
    // 会产出`-`(删空)+尾部` `(上下文)；合法链尾部上下文越界时
    // expected必为空，此时放行；非空期望越界仍抛错（真漂移）。
    // R3-V1d：空白对空白放行——生成器尾部幽灵` `(上下文) vs
    // 实际串尾`''`，strip后皆空不算漂移（D3回归：backup生成时
    // prev重建被尾部幽灵行杀掉致prev成空，备份diff坏掉）。
    // 真漂移（内容行对不上）仍然抛错。
    final actual = index < lines.length ? lines[index] : '';
    if (actual != expected) {
      if (actual.trim().isEmpty && expected.trim().isEmpty) return;
      throw StateError('差量与工作区内容不匹配：文件在回退后被修改过，请重新检查后再操作');
    }
  }

  /// tree 文件缺失时抛错，不静默返回空。
  /// 空 tree 意味着"删光工作区"，静默会让版本库损坏时 restore 误删全部文件。
  /// 调用方需区分：全新空仓库走 `_checkpoints.isEmpty` 判断，不调本方法。
  Future<Map<String, String>> _loadTree(String id) async {
    if (!_isSafeVersionId(id)) {
      throw StateError('非法版本 id：$id');
    }
    // 缓存与落盘一致性：旧 snapshots 兼容分支回写缓存时可能滞留毒化 key，
    // 每次命中先复检门禁，脏 key 即清缓存重读落盘，不展示毒化路径。
    if (_treeCache.containsKey(id)) {
      final cached = Map<String, String>.from(_treeCache[id]!);
      final rootPath = _rootPath;
      if (rootPath == null) return cached;
      var dirty = false;
      for (final k in cached.keys) {
        if (!_isSafeRestoreRel(rootPath, k)) {
          dirty = true;
          break;
        }
      }
      if (!dirty) return cached;
      _treeCache.remove(id);
    }
    final versions = _versionsDir;
    if (versions == null) {
      throw StateError('版本库不可用，无法读取版本 $id');
    }

    final treeFile = File(p.join(versions.path, 'trees', '$id.json'));
    if (await treeFile.exists()) {
      try {
        final data =
            jsonDecode(await treeFile.readAsString()) as Map<String, dynamic>;
        final files = <String, String>{};
        final raw = data['files'];
        if (raw is Map) {
          // 毒化 tree 过滤：crafted key（如 ../../x、绝对路径）在落盘成
          // ops 前各处虽有 _isSafeRestoreRel 复检，但 _loadTree 缓存污染后
          // diffTextOf/fileContentAt 会展示毒化路径内容。此处加载即清洗，
          // 脏 key 不进内存 tree/diff 缓存。
          final rootPath = _rootPath;
          raw.forEach((k, v) {
            final key = '$k';
            if (rootPath != null && !_isSafeRestoreRel(rootPath, key)) return;
            files[key] = '$v';
          });
        }
        _treeCache[id] = files;
        _boundVersionCaches();
        return Map<String, String>.from(files);
      } catch (_) {}
    }

    // 兼容旧 snapshots/<id>/：现算 hash，不回写 blob（避免悄悄占空间）
    final dir = Directory(p.join(versions.path, 'snapshots', id));
    if (!await dir.exists()) {
      throw StateError('版本数据缺失：找不到版本 $id 的 tree 记录');
    }
    final result = <String, String>{};
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: dir.path);
      // 兼容分支同样清洗：snapshots 下 crafted 文件名不进 tree，防缓存污染。
      final rootPath = _rootPath;
      if (rootPath != null && !_isSafeRestoreRel(rootPath, rel)) continue;
      try {
        // R9-A2 兼容分支同样2MB门禁：主分支_capture/_filePayload有门禁，
        // 旧snapshots兼容分支此前直读，大文件即OOM。
        try {
          if (await entity.length() > 2 * 1024 * 1024) continue;
        } catch (_) {}
        final bytes = await entity.readAsBytes();
        result[rel] = sha1.convert(bytes).toString();
      } catch (_) {}
    }
    _treeCache[id] = result;
    _boundVersionCaches();
    return Map<String, String>.from(result);
  }

  List<FileChange> _diffTrees(
    Map<String, String> prev,
    Map<String, String> current,
  ) {
    final changes = <FileChange>[];
    final allKeys = {...prev.keys, ...current.keys}.toList()..sort();
    for (final key in allKeys) {
      final inPrev = prev.containsKey(key);
      final inCurrent = current.containsKey(key);
      if (!inPrev && inCurrent) {
        changes.add(FileChange(path: key, type: 'added', hash: current[key]));
      } else if (inPrev && !inCurrent) {
        changes.add(FileChange(path: key, type: 'deleted', hash: prev[key]));
      } else if (prev[key] != current[key]) {
        changes.add(
          FileChange(path: key, type: 'modified', hash: current[key]),
        );
      }
    }
    return changes;
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

  Future<List<FileChange>> _materializeDiffs({
    required List<FileChange> changes,
    required Map<String, String> prevFiles,
    required Map<String, String> currentFiles,
    String? prevId,
    String? currentId,
    bool currentFromWorkspace = false,
    Map<String, String>? currentTexts,
  }) async {
    final out = <FileChange>[];
    for (final c in changes) {
      final prev = await _filePayload(
        path: c.path,
        hash: prevFiles[c.path],
        versionId: prevId,
      );
      final current = await _filePayload(
        path: c.path,
        hash: currentFiles[c.path],
        fromWorkspace: currentFromWorkspace,
        versionId: currentFromWorkspace ? null : currentId,
        knownText: currentTexts?[c.path],
      );
      final binary = prev.binary || current.binary;
      if (binary) {
        await _persistBinaryPayload(prevFiles[c.path], prev);
        await _persistBinaryPayload(currentFiles[c.path], current);
        out.add(
          FileChange(
            path: c.path,
            type: c.type,
            hash: c.hash,
            binary: true,
            diff: '@@ binary ${c.type} ${c.path} @@',
          ),
        );
        continue;
      }
      out.add(
        FileChange(
          path: c.path,
          type: c.type,
          hash: c.hash,
          diff: _lineDiffText(
            prev.text ?? '',
            current.text ?? '',
            c.path,
            lossy: false,
          ),
        ),
      );
    }
    return out;
  }

  Future<void> _persistBinaryPayload(String? hash, _FilePayload payload) async {
    if (hash == null || payload.bytes == null) return;
    if (await _blobExists(hash)) return;
    await _writeBlob(hash, payload.bytes!);
  }

  Future<String> lineDiff(String id, String relPath) async {
    if (!_isSafeVersionId(id)) return '';
    final changes = await changesOf(id);
    for (final c in changes) {
      if (c.path == relPath &&
          c.diff.isNotEmpty &&
          !c.diff.endsWith('+++ b/$relPath')) {
        // 已有真实 diff（不是旧占位头）
        if (c.diff.contains('\n@@ ') ||
            c.diff.contains('\n+') ||
            c.diff.contains('\n-')) {
          return c.diff;
        }
      }
    }

    final versions = _versionsDir;
    if (versions == null) return '';
    final diffFile = File(p.join(versions.path, 'diffs', '$id.json'));
    String? prevId;
    try {
      final data =
          jsonDecode(await diffFile.readAsString()) as Map<String, dynamic>;
      prevId = data['prevId'] as String?;
    } catch (_) {}
    final newContent = await fileContentAt(id, relPath) ?? '';
    final oldContent = prevId == null
        ? ''
        : await fileContentAt(prevId, relPath) ?? '';
    return _lineDiffText(oldContent, newContent, relPath);
  }

  String _lineDiffText(
    String oldText,
    String newText,
    String path, {
    bool lossy = true,
  }) {
    final a = oldText.split('\n');
    final b = newText.split('\n');
    final buf = StringBuffer('--- a/$path\n+++ b/$path\n');
    const maxLines = 2000;
    final truncated = lossy && (a.length > maxLines || b.length > maxLines);
    final aa = truncated && a.length > maxLines ? a.sublist(0, maxLines) : a;
    final bb = truncated && b.length > maxLines ? b.sublist(0, maxLines) : b;
    if (aa.length * bb.length > 4 * 1000 * 1000) {
      if (!lossy) return _lineDiffGreedy(a, b, path);
      buf.writeln('@@ 文件过大（${a.length}/${b.length} 行，仅对比前 $maxLines 行） @@');
      final n = aa.length < bb.length ? aa.length : bb.length;
      for (var i = 0; i < n; i++) {
        if (aa[i] == bb[i]) continue;
        buf.writeln('-${aa[i]}');
        buf.writeln('+${bb[i]}');
        if (buf.length > 20000) {
          buf.writeln('…（diff 过长已截断，请直接查看文件）');
          break;
        }
      }
      if (truncated) buf.writeln('…（超出 $maxLines 行部分未对比）');
      return buf.toString();
    }
    final lcs = _lcsTable(aa, bb);
    var i = aa.length;
    var j = bb.length;
    final ops = <String>[];
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && aa[i - 1] == bb[j - 1]) {
        ops.add(' ${aa[i - 1]}');
        i--;
        j--;
      } else if (j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j])) {
        ops.add('+${bb[j - 1]}');
        j--;
      } else if (i > 0) {
        ops.add('-${aa[i - 1]}');
        i--;
      } else {
        break;
      }
    }
    final ordered = ops.reversed.toList();
    var oldLine = 1;
    var newLine = 1;
    var idx = 0;
    while (idx < ordered.length) {
      while (idx < ordered.length && ordered[idx].startsWith(' ')) {
        oldLine++;
        newLine++;
        idx++;
      }
      if (idx >= ordered.length) break;
      final hunkStart = idx;
      var oldCount = 0;
      var newCount = 0;
      final hunkOldStart = oldLine;
      final hunkNewStart = newLine;
      final ctxBefore = <String>[];
      var back = hunkStart - 1;
      while (back >= 0 &&
          ordered[back].startsWith(' ') &&
          ctxBefore.length < 3) {
        ctxBefore.insert(0, ordered[back]);
        back--;
      }
      final emit = <String>[...ctxBefore];
      oldCount += ctxBefore.length;
      newCount += ctxBefore.length;
      final adjustedOldStart = hunkOldStart - ctxBefore.length;
      final adjustedNewStart = hunkNewStart - ctxBefore.length;

      while (idx < ordered.length) {
        final op = ordered[idx];
        if (op.startsWith(' ')) {
          var look = idx;
          var spaces = 0;
          while (look < ordered.length &&
              ordered[look].startsWith(' ') &&
              spaces < 7) {
            spaces++;
            look++;
          }
          if (spaces >= 7) {
            for (var k = 0; k < 3 && idx < ordered.length; k++) {
              emit.add(ordered[idx]);
              oldCount++;
              newCount++;
              oldLine++;
              newLine++;
              idx++;
            }
            break;
          }
          emit.add(op);
          oldCount++;
          newCount++;
          oldLine++;
          newLine++;
          idx++;
        } else if (op.startsWith('+')) {
          emit.add(op);
          newCount++;
          newLine++;
          idx++;
        } else if (op.startsWith('-')) {
          emit.add(op);
          oldCount++;
          oldLine++;
          idx++;
        } else {
          idx++;
        }
      }
      buf.writeln(
        '@@ -$adjustedOldStart,$oldCount +$adjustedNewStart,$newCount @@',
      );
      for (final line in emit) {
        buf.writeln(line);
      }
    }
    if (ordered.isEmpty) {
      buf.writeln('@@ -1,0 +1,0 @@');
    }
    return buf.toString();
  }

  List<List<int>> _lcsTable(List<String> a, List<String> b) {
    // 第1轮R3-1：超限抛错不再分配。
    if (a.length * b.length > 4 * 1000 * 1000) {
      throw StateError('diff过大已转贪心路径');
    }
    final dp =
        List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
    for (var x = 1; x <= a.length; x++) {
      for (var y = 1; y <= b.length; y++) {
        dp[x][y] = a[x - 1] == b[y - 1]
            ? dp[x - 1][y - 1] + 1
            : (dp[x - 1][y] > dp[x][y - 1] ? dp[x - 1][y] : dp[x][y - 1]);
      }
    }
    return dp;
  }

  /// 第1轮R3-1测试钩子：超限抛错口径（不分配矩阵）。
  List<List<int>> debugLcsTableForTest(List<String> a, List<String> b) =>
      _lcsTable(a, b);

  /// 大文件无损差量：线性扫一遍找同步点，不截断、不建 LCS 矩阵。
  String _lineDiffGreedy(List<String> a, List<String> b, String path) {
    final buf = StringBuffer('--- a/$path\n+++ b/$path\n');
    var i = 0;
    var j = 0;
    var emitted = false;
    while (i < a.length || j < b.length) {
      if (i < a.length && j < b.length && a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      final oldStart = i + 1;
      final newStart = j + 1;
      final dels = <String>[];
      final adds = <String>[];
      var found = false;
      for (var ni = i; ni < a.length && !found; ni++) {
        final limit = j + 256 < b.length ? j + 256 : b.length;
        for (var nj = j; nj < limit; nj++) {
          if (a[ni] == b[nj]) {
            dels.addAll(a.sublist(i, ni));
            adds.addAll(b.sublist(j, nj));
            i = ni;
            j = nj;
            found = true;
            break;
          }
        }
      }
      if (!found) {
        dels.addAll(a.sublist(i));
        adds.addAll(b.sublist(j));
        i = a.length;
        j = b.length;
      }
      buf.writeln('@@ -$oldStart,${dels.length} +$newStart,${adds.length} @@');
      for (final line in dels) {
        buf.writeln('-$line');
      }
      for (final line in adds) {
        buf.writeln('+$line');
      }
      emitted = true;
    }
    if (!emitted) buf.writeln('@@ -1,0 +1,0 @@');
    return buf.toString();
  }

  Future<void> _syncPathToLatest(
    String relativePath, {
    String? excludeId,
  }) async {
    final root = _rootPath;
    if (root == null) return;
    // 毒化 path 防护：diffs 里的 crafted path（如 ../../x）不得删出区外，
    // 此前删除分支不走 _commitOps 门禁，直接拼接删除。
    if (!_isSafeRestoreRel(root, relativePath)) return;
    final ordered = _orderedOldToNew()
        .where((e) => e.id != excludeId)
        .toList(growable: false);
    // 排除安全节点后有效历史为空：说明回退删光了版本链，
    // 此时保持现场（安全节点内容）不动，不删文件，避免数据丢失。
    final effective = ordered.isEmpty && excludeId != null
        ? _orderedOldToNew()
              .where((e) => e.id == excludeId)
              .toList(growable: false)
        : ordered;
    final latestTree = effective.isEmpty
        ? <String, String>{}
        : await _loadTree(effective.last.id);
    if (!latestTree.containsKey(relativePath)) {
      final target = File(p.join(root, relativePath));
      if (await target.exists()) await target.delete();
      return;
    }
    final payload = await _filePayload(
      path: relativePath,
      hash: latestTree[relativePath],
      versionId: effective.last.id,
    );
    final bytes =
        payload.bytes ??
        (payload.text != null ? utf8.encode(payload.text!) : null);
    // R2-CK4：缺失抛错不谎报成功——此前静默return，调用方仍return true，
    // UI显示回退成功但磁盘未动。现抛错由调用方转失败提示。
    if (bytes == null) {
      throw StateError('版本数据缺失，无法回退：$relativePath');
    }
    // D7-2：大文件直通保护（与 checkpoint :543、restore :1440 同口径）——
    // 盘上文件已被用户涨超 2MB 时跳过覆写，不用旧的小文件内容覆盖大文件。
    try {
      final target = File(p.join(root, relativePath));
      if (await target.exists() && await target.length() > 2 * 1024 * 1024) {
        AppLogger.instance.warn('checkpoint', '回退同步跳过超2MB大文件：$relativePath');
        return;
      }
    } catch (_) {}
    await _commitOps([_WsOp.write(relativePath, bytes)]);
  }

  /// 将工作区写成指定 path→hash tree。文本由差量链重建，二进制读 blob。
  /// 新内容只暂存 `.myide-new` 后改名覆盖；删除放到最后。失败用提交前算好的反向差量回滚。
  /// [currentSnapshot]：调用方已持有的工作区快照（restore 漂移复检通过后复用同一份，
  /// 避免二次捕获——两快照之间落盘的 Agent 写入会被目标树覆盖且不在 redo 保险内）。
  Future<void> _applyTreeToWorkspace(
    Map<String, String> desired, {
    String? versionId,
    Map<String, String>? currentSnapshot,
  }) async {
    final root = _rootPath;
    if (root == null) return;
    final current = currentSnapshot ?? await _captureWorkspace(root);
    final ops = <_WsOp>[];
    final missing = <String>[];
    for (final entry in desired.entries) {
      if (current[entry.key] == entry.value) continue;
      // R1-T2：大文件直通保留（恢复写侧）——盘上已涨超2MB时跳过覆写，
      // 此前按旧hash重建100B小文件覆盖用户3MB大文件。复现见大文件用例。
      try {
        final f = File(p.join(root, entry.key));
        if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
          continue;
        }
      } catch (_) {}
      final payload = await _filePayload(
        path: entry.key,
        hash: entry.value,
        versionId: versionId,
      );
      final bytes =
          payload.bytes ??
          (payload.text != null ? utf8.encode(payload.text!) : null);
      if (bytes == null) {
        missing.add('${entry.key}@${entry.value}');
        continue;
      }
      ops.add(_WsOp.write(entry.key, bytes));
    }
    if (missing.isNotEmpty) {
      throw StateError(
        '版本数据缺失 ${missing.length} 个文件：${missing.take(5).join(', ')}',
      );
    }
    // 大文件直通保留（恢复侧）：desired 缺席但盘上仍存在且超限，
    // 说明是 _captureWorkspace 主动跳过而非用户删除，不记 delete，
    // 否则 restore 会删掉用户的大文件。复现：小文件版→涨到3MB→restore旧版。
    for (final rel in current.keys) {
      if (!desired.containsKey(rel)) {
        try {
          final f = File(p.join(root, rel));
          if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
            continue;
          }
        } catch (_) {}
        ops.add(_WsOp.delete(rel));
      }
    }
    await _commitOps(ops);
  }

  Future<void> _applyChangesToWorkspace(List<FileChange> changes) async {
    final root = _rootPath;
    if (root == null) return;
    final ops = <_WsOp>[];
    final missing = <String>[];
    for (final c in changes) {
      if (c.type == 'deleted') {
        // 第7轮N7：>2MB 直通保护对称——restore 删大文件被跳过（1730-1740），
        // redo 回放同样跳过（restore 没动它，回放也不动）。
        try {
          final f = File(p.join(root, c.path));
          if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
            continue;
          }
        } catch (_) {}
        ops.add(_WsOp.delete(c.path));
        continue;
      }
      // 第7轮N7：>2MB modified/added 文本文件跳过——redo.json 跨重启后
      // patch 可注入任意大文件，readAsString 全文进内存可 OOM。与 restore
      // 直通保护对称（restore 没写它，回放也不写）。
      if (!c.binary) {
        try {
          final f = File(p.join(root, c.path));
          if (await f.exists() && await f.length() > 2 * 1024 * 1024) {
            continue;
          }
        } catch (_) {}
      }
      if (c.binary) {
        if (c.hash == null) {
          missing.add(c.path);
          continue;
        }
        final bytes = await _readBlobBytes(c.hash!);
        if (bytes == null) {
          missing.add('${c.path}@${c.hash}');
          continue;
        }
        ops.add(_WsOp.write(c.path, bytes));
        continue;
      }
      final file = File(p.join(root, c.path));
      final current = await file.exists() ? await file.readAsString() : '';
      final next = _applyUnifiedDiff(
        c.type == 'added' ? '' : current,
        c.diff,
        validateContext: c.type != 'added',
      );
      ops.add(_WsOp.write(c.path, utf8.encode(next)));
    }
    if (missing.isNotEmpty) {
      throw StateError(
        '版本数据缺失 ${missing.length} 个文件：${missing.take(5).join(', ')}',
      );
    }
    await _commitOps(ops);
  }

  Future<void> _replaceOver(File tmp, File target) async {
    // 权限保留：覆盖前记下可执行位，rename 后 chmod 回去，
    // 此前全库无 mode 复制，脚本恢复后丢可执行位。
    var executable = false;
    try {
      if (!Platform.isWindows && await target.exists()) {
        final mode = (await target.stat()).mode;
        executable = (mode & 0x49) != 0;
      }
    } catch (_) {}
    // R1-Win同口径：Windows三步原子（目标→.bak→新→目标→删bak），
    // 与agent_tools._writeFileAtomic一致，崩溃窗口不丢版本文件。
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
    if (executable && !Platform.isWindows) {
      try {
        await Process.run('chmod', ['+x', target.path]);
      } catch (_) {}
    }
  }

  /// 恢复路径门禁：拒绝对路径/`..` 越界/空路径/链接侧车文件，
  /// 与 WorkspaceFs.zoneOf 基准一致。版本文件被篡改或拷贝不可信项目
  /// 注入 `../../` 时在此拦截，不再直写区外。
  /// 另拦截父目录链接逃逸、敏感路径、版本库自毁（.my_ide/versions）。
  bool _isSafeRestoreRel(String root, String rel) {
    if (rel.isEmpty) return false;
    if (p.isAbsolute(rel)) return false;
    if (_isTempSidecar(rel)) return false;
    final normalized = p.normalize(rel);
    if (normalized == '.' || normalized.startsWith('..')) return false;
    if (normalized.split(p.separator).contains('..')) return false;
    // 版本库自毁拦截：crafted tree/diff 此前可覆盖 manifest/redo/blob。
    final lower = normalized.replaceAll('\\', '/').toLowerCase();
    if (lower == '.my_ide' ||
        lower.startsWith('.my_ide/versions/') ||
        lower == '.my_ide/versions' ||
        WorkspaceFs.isSensitiveRelative(normalized)) {
      return false;
    }
    final abs = p.normalize(p.join(root, normalized));
    final rootNorm = p.normalize(root);
    if (abs != rootNorm && !p.isWithin(rootNorm, abs)) return false;
    // 恢复拒 symlink：目标现为链接时读跟随、写替换分裂，此前行为不一致。
    // 检测到链接直接中止，由用户手动处理，避免写到区外。
    try {
      final type = FileSystemEntity.typeSync(abs, followLinks: false);
      if (type == FileSystemEntityType.link) return false;
      // 父目录链同样拦截：a/link->/etc 时 `a/link/file` 词法在区内，
      // 此前 parent.create+write 会跟随出狱。
      var dir = Directory(p.dirname(abs));
      final rootReal = WorkspaceFs.realpathOf(rootNorm);
      for (var i = 0; i < 32; i++) {
        if (dir.path == rootNorm || dir.path == rootReal) break;
        try {
          final t = FileSystemEntity.typeSync(dir.path, followLinks: false);
          if (t == FileSystemEntityType.link) return false;
        } catch (_) {
          // R1-A4 fail-closed：探测异常按可疑拒绝，不再 break 放行。
          return false;
        }
        final parent = p.dirname(dir.path);
        if (parent == dir.path) break;
        dir = Directory(parent);
        if (!p.isWithin(rootNorm, dir.path) && dir.path != rootNorm) {
          return false;
        }
      }
    } catch (_) {
      // R1-A4 fail-closed：外层异常同样拒绝。
      return false;
    }
    return true;
  }

  Future<void> _commitOps(List<_WsOp> ops) async {
    // 第6轮R6-1：去死参——失败回滚用提交前字节，不再消费 reverse diff，
    // 保留参数只为调用兼容的历史包袱已清，调用方同步去参。
    if (ops.isEmpty) return;
    final root = _rootPath!;
    // 恢复链统一门禁：tree/diff/manifest 被篡改注入 `../../` 时拒写区外，
    // 与 WorkspaceFs.zoneOf 基准一致（拒绝对路径/越界/敏感路径）。
    for (final op in ops) {
      if (!_isSafeRestoreRel(root, op.rel)) {
        throw StateError('版本数据含非法路径，已中止恢复：${op.rel}');
      }
    }
    final staged = <File>[];
    final committed = <_WsOp>[];
    final originals = <String, List<int>?>{};
    // 第2轮R2-2：三分语义——此前over与不存在共用null，回滚prior==null分支
    // 把create残留当大文件跳过不清。现oversized集合隔离：null=原不存在
    // （回滚删除），[]=超大哨兵（回滚保留现场），其余=原字节。
    final oversized = <String>{};
    for (final op in ops) {
      final target = File(p.join(root, op.rel));
      try {
        // 第1轮N1大小门禁 + 第2轮R2-1读后复检：length→read间隙涨大即按超大
        // 处理，不驻留GB。来源Roo Code checkpoints按需读盘口径（采纳大文件
        // 豁免防OOM；不采纳依赖git安装）。
        final over = await target.exists() && await target.length() > 2 * 1024 * 1024;
        if (over) {
          oversized.add(op.rel);
          originals[op.rel] = const <int>[];
        } else if (await target.exists()) {
          final snap = await target.readAsBytes();
          if (snap.length > 2 * 1024 * 1024) {
            oversized.add(op.rel);
            originals[op.rel] = const <int>[];
          } else {
            originals[op.rel] = snap;
          }
        } else {
          originals[op.rel] = null;
        }
      } catch (_) {
        oversized.add(op.rel);
        originals[op.rel] = const <int>[];
      }
    }
    try {
      for (final op in ops) {
        if (op.delete) continue;
        final target = File(p.join(root, op.rel));
        await target.parent.create(recursive: true);
        // R9-恢复侧车隔离：侧车此前与 AgentTools 同缀 `.myide-new`，
        // 并发恢复+Agent 写同文件可互盖侧车。现恢复侧车独立后缀互不干扰。
        op.stagedTmp = _stagingPath(target.path);
        final tmp = File(op.stagedTmp!);
        await tmp.writeAsBytes(op.bytes!, flush: true);
        staged.add(tmp);
      }
      for (final op in ops) {
        if (op.delete) continue;
        final target = File(p.join(root, op.rel));
        // 门禁后复检：parent.create 跟随父链外链，create→rename 窗口换链即写出区外，
        // 落盘前必须二次确认目标仍在区内且非链接。
        if (!_isSafeRestoreRel(root, op.rel)) {
          throw StateError('版本数据含非法路径，已中止恢复：${op.rel}');
        }
        if (CheckpointStore.debugFailBeforeRename?.call(op.rel) == true) {
          throw StateError('测试注入：改名前失败 ${op.rel}');
        }
        await _replaceOver(File(op.stagedTmp!), target);
        committed.add(op);
      }
      for (final op in ops) {
        if (!op.delete) continue;
        if (!_isSafeRestoreRel(root, op.rel)) {
          throw StateError('版本数据含非法路径，已中止恢复：${op.rel}');
        }
        final target = File(p.join(root, op.rel));
        // 删除拒链接：此前直删链接目标语义分裂，此处与恢复门禁对齐直接跳过。
        try {
          if (FileSystemEntity.typeSync(target.path, followLinks: false) ==
              FileSystemEntityType.link) {
            continue;
          }
        } catch (_) {}
        if (await target.exists()) await target.delete();
        committed.add(op);
      }
    } catch (e) {
      for (final op in committed.reversed) {
        try {
          final target = File(p.join(root, op.rel));
          final prior = originals[op.rel];
          // 第2轮R2-2续：回滚复检——失败窗口父链被换时回滚写/删即写穿区外。
          if (!_isSafeRestoreRel(root, op.rel)) continue;
          if (!originals.containsKey(op.rel) || prior == null) {
            if (await target.exists()) await target.delete();
          } else if (prior.isEmpty && oversized.contains(op.rel)) {
            // 超大哨兵保留现场；正常空文件不在oversized内，走写回分支。
            continue;
          } else {
            await _writeBytesAtomic(target, prior);
          }
        } catch (_) {}
      }
      for (final tmp in staged) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
    // R3-A4 成功路径清侧车：stage 侧车 rename 后源 tmp 已不在，
    // 此处尽力清残留（_replaceOver 抛错回滚路径的孤儿），不留垃圾。
    for (final tmp in staged) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// 最近一次被版本系统记录的状态索引：path → 所有版本 tree 里出现过的 hash。
  /// 仅在存在未记录漂移候选时才构建（复用 _treeCache，成本可控）。
  Future<Map<String, Set<String>>> _recordedHashesByPath() async {
    final out = <String, Set<String>>{};
    for (final cp in _checkpoints) {
      try {
        final tree = await _loadTree(cp.id);
        tree.forEach((path, hash) {
          (out[path] ??= <String>{}).add(hash);
        });
      } catch (_) {}
    }
    return out;
  }

  /// A4：找出本次恢复将改写、但盘上内容未被版本系统记录的文件。
  /// 判定口径：盘上 hash 与最新节点 tree 不一致，且也不在任何历史 tree 中
  /// （历史 tree 出现过即"已被记录"，如上一次 restore 留下的现场）——
  /// 这正是"用户在快照后改动过且未被版本系统记录"的集合。
  /// >2MB 大文件由直通保护保证不写不删，无需拒绝；基线不可读时不拒绝，
  /// 交给 Redo 保险与漂移复检兜底。
  Future<Set<String>> _unrecordedDriftPaths({
    required Map<String, String> desired,
    required Map<String, String> current,
  }) async {
    final root = _rootPath;
    if (root == null || _checkpoints.isEmpty) return {};
    Map<String, String> newest;
    try {
      // manifest 数组头即最新节点：其 tree 是最近一次被记录的现场。
      newest = await _loadTree(_checkpoints.first.id);
    } catch (_) {
      return {};
    }
    Map<String, Set<String>>? recorded;
    final refused = <String>{};
    for (final path in {...desired.keys, ...current.keys}) {
      final cur = current[path];
      final des = desired[path];
      // 本次恢复不会改写的文件无需拒绝。
      if (cur != null && cur == des) continue;
      try {
        final f = File(p.join(root, path));
        if (await f.exists() && await f.length() > 2 * 1024 * 1024) continue;
      } catch (_) {}
      if (cur == newest[path]) continue;
      if (cur != null) {
        recorded ??= await _recordedHashesByPath();
        if (recorded[path]?.contains(cur) == true) continue;
      }
      refused.add(path);
    }
    return refused;
  }

  /// 恢复工作区到指定版本。
  /// A4（Aider git 口径）：恢复前逐文件比对盘上内容与版本库已记录状态，
  /// 用户在快照后改动过且未被任何版本记录的文件默认拒绝恢复（不整批失败，
  /// 其余文件正常恢复）；[force] 为 true 时忽略拒绝强制覆盖。
  /// 返回被拒文件路径列表（已排序）；未记录改动的数据安全仍由先行的
  /// Redo 保险兜底，与漂移复检（恢复期间变化即中止）口径互不替代。
  Future<List<String>> restoreWorkspaceTo(
    String versionId, {
    bool force = false,
  }) async {
    if (!_isSafeVersionId(versionId)) throw StateError('非法版本 id');
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    final root = _rootPath;
    if (root == null) throw StateError('未打开项目');
    _busy = true;
    // R2-06 restore 写盘互斥+审批不复用：_busy 只拦版本操作不拦 Agent 写盘，
    // 此处登记全局 restore 世代，AgentTools 写盘侧见 restore 在途即排队等待
    // （而非仅事后指纹中止），C/R 安全论文口径：恢复边界必须覆盖写依赖。
    _bumpRestoreGen();
    final myGen = _restoreGenLocal;
    notifyListeners();
    // 高风险前 push：开启时先推远端，失败只记日志不抛错。
    try {
      if (await GitAnchor.prefsPushBeforeRisky()) {
        final pushed = await GitAnchor.maybePushBeforeRisky(root);
        if (!pushed) {
          AppLogger.instance.warn('checkpoint', '恢复前 push 失败，继续本地恢复');
        }
      }
    } catch (_) {}
    try {
      // restore 起点快照钉住：_captureWorkspace → 建 redo 保险 → 应用树
      // 三段之间 Agent/外部写入会让保险与落盘基线分叉（丢写/回滚错位）。
      // _busy 已阻止第二路版本操作，但不阻止 Agent 写盘；此处记录基线
      // 生成时的树指纹，恢复提交按树重算、提交前验证漂移并中止。
      final current = await _captureWorkspace(root);
      final toFiles = await _loadTree(versionId);
      final currentDigest = _treeDigest(current);
      // 先建立 Redo 保险，失败则中止恢复：
      // 恢复会删除目标树之外的文件，没有 Redo 兜底会造成不可恢复丢失。
      final List<FileChange> reverse;
      try {
        reverse = await _materializeDiffs(
          changes: _diffTrees(toFiles, current),
          prevFiles: toFiles,
          currentFiles: current,
          prevId: versionId,
          currentFromWorkspace: true,
        );
      } catch (e) {
        AppLogger.instance.error('checkpoint', '建立回退保险失败，已中止恢复', e);
        throw StateError('无法建立回退保险，已中止恢复：$e');
      }
      _redoPatches.add(reverse);
      final redoLabel =
          'Restore 前现场 ${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}';
      _redoLabels.add(redoLabel);
      while (_redoPatches.length > 20) {
        _redoPatches.removeAt(0);
        _redoLabels.removeAt(0);
      }
      await _saveRedoStack();
      // 提交前验证漂移：建保险后工作区若被 Agent/外部改动，
      // redo 保险基于旧现场，直接应用目标树会静默丢写。此时中止恢复，
      // 调用方重试即基于新现场重建保险。
      final recheck = await _captureWorkspace(root);
      if (_treeDigest(recheck) != currentDigest) {
        throw StateError('恢复期间工作区发生变化，已中止恢复避免丢写：请重试');
      }
      // 世代校验：并发第二路 restore 已推进世代时，本路基线已过期，直接中止。
      if (myGen != _restoreGenLocal) {
        throw StateError('恢复期间有新恢复启动，已中止旧恢复避免错位');
      }
      // A4：未记录改动文件默认拒绝（force 绕过）。被拒文件钉在当前现场——
      // 不覆写不删除；并从 Redo 保险中剔除（恢复不触碰它们，Redo 才能整体
      // 回放到恢复前现场）。拒绝判定在漂移复检之后：复检保证此刻盘上内容
      // 仍等于 current，逐文件判定才与提交内容一致。
      final refused = <String>[];
      if (!force) {
        refused.addAll(
          await _unrecordedDriftPaths(desired: toFiles, current: current),
        );
        refused.sort();
      }
      var effectiveDesired = toFiles;
      if (refused.isNotEmpty) {
        AppLogger.instance.warn(
          'checkpoint',
          '恢复拒绝覆盖未记录改动 ${refused.length} 个文件：${refused.take(5).join(', ')}',
        );
        effectiveDesired = Map<String, String>.from(toFiles);
        for (final path in refused) {
          final cur = current[path];
          if (cur != null) {
            effectiveDesired[path] = cur;
          } else {
            effectiveDesired.remove(path);
          }
        }
        try {
          final refined = await _materializeDiffs(
            changes: _diffTrees(effectiveDesired, current),
            prevFiles: effectiveDesired,
            currentFiles: current,
            prevId: versionId,
            currentFromWorkspace: true,
          );
          _redoPatches.removeLast();
          _redoLabels.removeLast();
          _redoPatches.add(refined);
          _redoLabels.add(redoLabel);
          await _saveRedoStack();
        } catch (_) {
          // 重建失败保留原全量保险：数据安全优先，Redo 或需漂移校验兜底。
        }
      }
      await _applyTreeToWorkspace(
        effectiveDesired,
        versionId: versionId,
        // D7-3：复检通过后复用同一 current 快照，不再二次 _captureWorkspace——
        // 两快照之间落盘的 Agent 写入会被目标树覆盖且不在 redo 保险内。
        currentSnapshot: current,
      );
      notifyListeners();
      // 遥测：恢复成功后记一条（仅数量）。
      try {
        await Telemetry.record('restore', {
          'count': effectiveDesired.length,
        });
      } catch (_) {}
      return refused;
    } finally {
      _busy = false;
      // restore 结束即推进世代：写盘侧排队者凭世代变化放行，避免永久等待。
      _bumpRestoreGen();
      notifyListeners();
    }
  }

  /// R2-06 写盘侧排队：AgentTools 写盘前调此等待在途 restore。
  /// R2-02 稳静窗口防间隙醒早：busy+gen双条件不足——restore1结束
  /// （busy=false, gen已推进）到restore2开始（busy=true）存在间隙，
  /// 只看“busy=false且gen推进”仍在间隙醒早。现要求busy=false持续
  /// 稳静200ms才放行；新restore在窗口内启动即重新等待。
  /// 无在途（busy=false）直接返回。
  static Future<void> waitForNoRestore({
    required int enterGen,
    required bool Function() restoreBusy,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!restoreBusy()) return;
    final deadline = DateTime.now().add(timeout);
    DateTime? quietSince;
    while (true) {
      if (!DateTime.now().isBefore(deadline)) {
        throw StateError('等待恢复完成超时');
      }
      if (restoreBusy()) {
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

  /// 弹出最近一次 Restore 前差量并写回工作区，返回标签；空栈返回 null。
  Future<String?> redoLastRestore() async {
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    if (_redoPatches.isEmpty) return null;
    if (_rootPath == null) throw StateError('未打开项目');
    _busy = true;
    // R7-01：redo 同样是恢复类写盘（与 restore/revert 同族），推进 restore
    // 世代，写盘侧排队可见 redo 在途；结束再+1 放行。
    _bumpRestoreGen();
    notifyListeners();
    try {
      // R11-7-A 先窥视后执行：此前removeLast+save后才apply，崩在save后apply前
      // 唯一回退数据丢（与commit journal不对称）。现先窥视栈顶，apply成功再弹栈落盘。
      final patch = _redoPatches.last;
      final label = _redoLabels.isNotEmpty ? _redoLabels.last : 'Redo';
      // Redo 前快照现场：半落盘时按快照直恢复，不再删成缺失。
      final root = _rootPath!;
      final snapshots = <String, List<int>?>{};
      // 第1轮R3-2：超大哨兵集合隔离——此前>2MB用[]哨兵与正常空文件[]同值，
      // 回滚bytes.isEmpty分支把空文件误判为大文件保留现场跳过恢复。
      // 现oversized集合单独记录，空文件走正常写回。
      final oversized = <String>{};
      for (final c in patch) {
        // 快照与回滚同样走恢复门禁：redo.json 被篡改注入 `../` 时，
        // 此前快照直读、回滚直写可读写区外，旁路 _isSafeRestoreRel。
        if (!_isSafeRestoreRel(root, c.path)) {
          throw StateError('版本数据含非法路径，已中止恢复：${c.path}');
        }
        try {
          final f = File(p.join(root, c.path));
          // 第7轮N7：大小门禁——此前裸读全文，redo.json 跨重启持久化后
          // patch 内文件可任意大，快照全文进内存可 OOM。>2MB 存空列表哨兵
          //（回滚保留现场不误删），null 仍表示"原不存在"（回滚删除）。
          final over = await f.exists() && await f.length() > 2 * 1024 * 1024;
          if (over) oversized.add(c.path);
          snapshots[c.path] = over
              ? const <int>[]
              : (await f.exists() ? await f.readAsBytes() : null);
        } catch (_) {
          snapshots[c.path] = null;
        }
      }
      try {
        await _applyChangesToWorkspace(patch);
      } catch (_) {
        for (final entry in snapshots.entries) {
          // 回滚同样复检门禁：快照 key 即 patch 路径，理论已验，双重保险。
          if (!_isSafeRestoreRel(root, entry.key)) continue;
          try {
            final f = File(p.join(root, entry.key));
            final bytes = entry.value;
            if (bytes == null) {
              if (await f.exists()) await f.delete();
            } else if (bytes.isEmpty && oversized.contains(entry.key)) {
              // 第7轮N7：>2MB 哨兵——restore 直通保护没动它，回滚保留现场
              // 不误删（此前与"原不存在"共用 null 语义会删大文件）。
              // 第1轮R3-2续：仅oversized集合内才跳过，正常空文件写回空文件。
              continue;
            } else {
              await f.parent.create(recursive: true);
              await _writeBytesAtomic(f, bytes);
            }
          } catch (_) {}
        }
        // 先窥视未弹栈：应用失败栈顶仍在，无需放回，直接抛错。
        rethrow;
      }
      // apply成功再弹栈落盘：崩在apply前栈顶仍在可重试，不丢数据。
      _redoPatches.removeLast();
      if (_redoLabels.isNotEmpty) _redoLabels.removeLast();
      await _saveRedoStack();
      notifyListeners();
      return label;
    } finally {
      _busy = false;
      // R7-01：redo 结束推进世代放行排队者。
      _bumpRestoreGen();
      notifyListeners();
    }
  }

  /// 按时间旧→新重算剩余节点的 prev 链接与 diff。
  Future<void> _relinkDiffs() async {
    final versions = _versionsDir;
    if (versions == null) return;
    final ordered = _orderedOldToNew();
    String? prevId;
    for (final cp in ordered) {
      final tree = await _loadTree(cp.id);
      final prevTree = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);
      final changes = await _materializeDiffs(
        changes: _diffTrees(prevTree, tree),
        prevFiles: prevTree,
        currentFiles: tree,
        prevId: prevId,
        currentId: cp.id,
      );
      final diffFile = File(p.join(versions.path, 'diffs', '${cp.id}.json'));
      await _writeFileAtomic(
        diffFile,
        jsonEncode({
          'id': cp.id,
          'prevId': prevId,
          'changes': changes.map((e) => e.toJson()).toList(),
        }),
      );
      _diffCache[cp.id] = changes;
      _boundVersionCaches();
      prevId = cp.id;
    }
    // manifest 顺序（新→旧）保持不变，不再重排。
  }

  Future<void> _deleteVersionArtifacts(String id) async {
    if (!_isSafeVersionId(id)) return;
    final versions = _versionsDir;
    if (versions == null) return;
    for (final rel in ['diffs/$id.json', 'trees/$id.json']) {
      try {
        final f = File(p.join(versions.path, rel));
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _diffCache.remove(id);
    _treeCache.remove(id);
  }

  /// blob GC：收集所有 tree 引用的 hash，无引用的 blob 文件删除，避免只涨不收。
  /// 为防误删进行中的写入，仅删 mtime 超过 1 小时的孤儿 blob。
  /// redo 栈引用的 hash 同样保留：redo 差量含二进制 hash，不统计会误删
  /// Redo 所需 blob，导致 Redo 时 missing 报错。
  /// R5：删前二次复查引用——收集与删除之间可能有并发 checkpoint 落盘新
  /// blob，删除前重载该 hash 的引用状态，已被引用即跳过。
  Future<int> gcBlobs() async {
    final versions = _versionsDir;
    if (versions == null) return 0;
    // 第9轮R9-1：未加载守卫——主备manifest双坏时内存_checkpoints为空，
    // referenced空即删光mtime>1h全库。与_gcOrphanArtifacts R2-CK1同口径收敛。
    if (!_manifestLoaded) return 0;
    final referenced = <String>{};
    // R2-CK5：任一tree加载失败即中止本轮——此前catch跳过致引用集不全，
    // 坏tree窗口可删live blob致restore/redo missing。现fail-closed返回0。
    for (final cp in _checkpoints) {
      try {
        final tree = await _loadTree(cp.id);
        referenced.addAll(tree.values);
      } catch (_) {
        return 0;
      }
    }
    for (final patch in _redoPatches) {
      for (final c in patch) {
        final h = c.hash;
        if (h != null && h.isNotEmpty) referenced.add(h);
      }
    }
    final blobsDir = Directory(p.join(versions.path, 'objects', 'blobs'));
    if (!await blobsDir.exists()) return 0;
    var removed = 0;
    final cutoff = DateTime.now().subtract(const Duration(hours: 1));
    // 收集时刻的节点 id：删除前只补查此后新增节点的 tree，避免全量重载。
    final knownIds = {for (final cp in _checkpoints) cp.id};
    await for (final entity in blobsDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: blobsDir.path);
      final hash = rel.replaceAll(RegExp(r'[/\\]'), '');
      if (hash.isEmpty || referenced.contains(hash)) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.isAfter(cutoff)) continue;
        // 删前复查：收集后新增的 checkpoint 可能引用该 blob。
        // R2-CK5续：删前全量复查tree+redo——此前只补查新增checkpoint的tree，
        // 并发新入Redo栈的hash不查。现逐hash重扫redo+新增tree。
        for (final cp in _checkpoints) {
          if (knownIds.contains(cp.id)) continue;
          try {
            final tree = await _loadTree(cp.id);
            referenced.addAll(tree.values);
          } catch (_) {
            // 复查期tree坏同样fail-closed：跳过该hash不删。
            referenced.add(hash);
            break;
          }
          knownIds.add(cp.id);
        }
        for (final patch in _redoPatches) {
          for (final c in patch) {
            final h = c.hash;
            if (h != null && h.isNotEmpty) referenced.add(h);
          }
        }
        if (referenced.contains(hash)) continue;
        await entity.delete();
        removed++;
      } catch (_) {}
    }
    return removed;
  }

  /// 删除指定版本节点，保留更新的节点并重算 diff 链。
  /// 必须先用完整差量链重算剩余节点，再删被丢弃节点；否则文本无法从差量重建。
  Future<void> dropVersions(Set<String> ids) async {
    if (ids.isEmpty) return;
    // revertDropVersions 借位调用：外层已占 _busy 并记了安全节点，
    // 此时允许同栈重入继续重链；外部并发仍抛错。
    final reentrant = _dropReentrancy > 0;
    if (_busy && !reentrant) {
      throw StateError('版本操作进行中，请稍后再试');
    }
    final owned = !_busy;
    if (owned) {
      _busy = true;
      notifyListeners();
    }
    try {
      // 非法 id 不进重链/删除路径：此前 crafted id 可穿越删版本库外 json。
      final safeIds = ids.where(_isSafeVersionId).toSet();
      final remaining = _orderedOldToNew()
          .where((e) => !safeIds.contains(e.id))
          .toList();
      String? prevId;
      for (final cp in remaining) {
        final tree = await _loadTree(cp.id);
        final prevTree = prevId == null
            ? <String, String>{}
            : await _loadTree(prevId);
        final changes = await _materializeDiffs(
          changes: _diffTrees(prevTree, tree),
          prevFiles: prevTree,
          currentFiles: tree,
          prevId: prevId,
          currentId: cp.id,
        );
        final versions = _versionsDir;
        if (versions != null) {
          final diffFile = File(
            p.join(versions.path, 'diffs', '${cp.id}.json'),
          );
          await _writeFileAtomic(
            diffFile,
            jsonEncode({
              'id': cp.id,
              'prevId': prevId,
              'changes': changes.map((e) => e.toJson()).toList(),
            }),
          );
        }
        _diffCache[cp.id] = changes;
        _boundVersionCaches();
        prevId = cp.id;
      }
      // R5：先落盘 manifest（指向已移除被删节点的剩余集），再删被删
      // 节点文件——旧顺序“删文件→存 manifest”在删后存前崩溃即悬指缺失 tree。
      _checkpoints.removeWhere((e) => safeIds.contains(e.id));
      await _saveManifest();
      for (final id in safeIds) {
        await _deleteVersionArtifacts(id);
      }
      try {
        await gcBlobs();
      } catch (_) {}
      notifyListeners();
    } finally {
      if (owned) {
        _busy = false;
        notifyListeners();
      }
    }
  }

  /// 取某版本在时间线上的前一个版本 id（旧→新）。
  String? previousVersionId(String versionId) {
    final ordered = _orderedOldToNew();
    final index = ordered.indexWhere((e) => e.id == versionId);
    if (index <= 0) return null;
    return ordered[index - 1].id;
  }

  /// 撤销若干版本对工作区的影响：若后续保留版本又改过同文件则保留后续结果。
  Future<Map<String, String>> _mergedWorkspaceWithout(
    Set<String> dropIds, {
    Set<String> excludeIds = const {},
  }) async {
    final ordered = _orderedOldToNew()
        .where((e) => !excludeIds.contains(e.id))
        .toList(growable: false);
    if (ordered.isEmpty) return {};

    // 从「第一个被删节点」之前的 tree 起步；若删的是最早节点则空 tree。
    var startIndex = 0;
    for (var i = 0; i < ordered.length; i++) {
      if (dropIds.contains(ordered[i].id)) {
        startIndex = i;
        break;
      }
      if (i == ordered.length - 1) {
        // 没有命中 drop：直接返回最新
        return _loadTree(ordered.last.id);
      }
    }
    Map<String, String> base;
    if (startIndex == 0) {
      base = {};
    } else {
      base = await _loadTree(ordered[startIndex - 1].id);
    }

    // 再叠加上所有「保留」节点相对其 prev 的变化
    String? prevId = startIndex == 0 ? null : ordered[startIndex - 1].id;
    for (var i = startIndex; i < ordered.length; i++) {
      final cp = ordered[i];
      final tree = await _loadTree(cp.id);
      final prevTree = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);
      if (dropIds.contains(cp.id)) {
        // 跳过该节点：不把变化叠进 base，但 prev 仍推进到该节点
        // （下一保留节点的 diff 会相对「被跳过节点」重算，见 dropVersions/_relink）
        prevId = cp.id;
        continue;
      }
      // 保留节点：把相对 prev 的变化叠到 base
      final allKeys = {...prevTree.keys, ...tree.keys};
      for (final path in allKeys) {
        final was = prevTree[path];
        final now = tree[path];
        if (was == now) continue;
        if (now == null) {
          base.remove(path);
        } else {
          base[path] = now;
        }
      }
      prevId = cp.id;
    }
    return base;
  }

  /// 「回撤到本轮」时扩展要删的节点：同一对话在区间内的节点，以及夹在中间的 user-edit。
  Set<String> expandDropForToTurn({
    required Set<String> seedIds,
    String? chatId,
  }) {
    if (seedIds.isEmpty) return seedIds;
    final ordered = _orderedOldToNew();
    var first = -1;
    var last = -1;
    for (var i = 0; i < ordered.length; i++) {
      if (!seedIds.contains(ordered[i].id)) continue;
      if (first < 0) first = i;
      last = i;
    }
    if (first < 0) return {...seedIds};
    final out = {...seedIds};
    for (var i = first; i <= last; i++) {
      final cp = ordered[i];
      if (chatId != null && cp.chatId == chatId) {
        out.add(cp.id);
        continue;
      }
      // 夹在中间、不属于其它对话的用户编辑一并去掉
      if (cp.kind == 'user-edit' &&
          (cp.chatId == null || cp.chatId == chatId)) {
        out.add(cp.id);
      }
    }
    return out;
  }

  /// 回退前把磁盘漂移（未进版本的改动）先记一个安全节点，
  /// 避免目标态由版本树推导时覆盖用户已落盘的编辑。
  /// 无漂移时 checkpoint() 返回 null，开销只是一次目录扫描。
  /// 返回新节点 id（无漂移返回 null）：调用方在重链/同步时必须排除它，
  /// 否则"同步到最新"会把刚备份的现场又写回去，回退失效。
  /// 安全节点保留在版本链中，可从版本面板再恢复。
  /// [allowBusyOwner] 为 true 时允许在外层已占 _busy 的情况下记安全节点：
  /// 外层先占位防并发，内层 checkpoint 借位执行后恢复占位，不真正释放。
  Future<String?> _safetyCheckpointIfDrifted({
    bool allowBusyOwner = false,
  }) async {
    final owned = allowBusyOwner && _busy;
    if (owned) _busy = false;
    try {
      final cp = await checkpoint(message: '回退前自动备份', kind: 'auto-backup');
      return cp?.id;
    } catch (_) {
      return null;
    } finally {
      if (owned) _busy = true;
    }
  }

  /// 回退：按剩余节点差量重链后写回工作区。不另做整文件快照。
  /// 中途失败抛错不销账（盘已回但账未销由调用方重试）。
  /// B9：借位窗口已收紧——外层先 _busy 占位，内层 checkpoint 不再临时清零，
  /// 而是直接借位执行（_safetyCheckpointIfDrifted allowBusyOwner），
  /// 窗口内第二个 revert/restore 见 _busy 直接抛错，不再交叉落盘。
  Future<void> revertDropVersions(Set<String> ids) async {
    if (ids.isEmpty) return;
    // 非法 id 不进重链/工作区同步：此前 crafted id 可穿越。
    final safeIds = ids.where(_isSafeVersionId).toSet();
    if (safeIds.isEmpty) return;
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    // 先占 _busy 再记安全节点：此前先 safetyCheckpoint（内部 checkpoint
    // 也走 _busy）后才置位，两路并发可同过检查、同跑安全节点后交叉落盘。
    // R6-01：回退同样推进 restore 世代，写盘侧排队可见回退在途。
    _busy = true;
    _bumpRestoreGen();
    notifyListeners();
    // 高风险前 push：开启时先推远端，失败只记日志不抛错。
    try {
      final r = _rootPath;
      if (r != null && await GitAnchor.prefsPushBeforeRisky()) {
        final pushed = await GitAnchor.maybePushBeforeRisky(r);
        if (!pushed) {
          AppLogger.instance.warn('checkpoint', '回退前 push 失败，继续本地回退');
        }
      }
    } catch (_) {}
    // 借位记安全节点：外层占位不释放，内层 checkpoint 临时借位执行。
    final safetyId = await _safetyCheckpointIfDrifted(allowBusyOwner: true);
    try {
      final desired = await _mergedWorkspaceWithout(
        safeIds,
        excludeIds: safetyId == null ? const {} : {safetyId},
      );
      // 第6轮R6-1：去死算——失败回滚由 _commitOps 按提交前字节直恢复，
      // 此处预先 _materializeDiffs 算 reverse 已无人消费，删 dead code。
      await _applyTreeToWorkspace(desired);
      _dropReentrancy++;
      try {
        await dropVersions(safeIds);
      } finally {
        _dropReentrancy--;
      }
      // 遥测：回撤成功后记一条（仅数量）。
      try {
        await Telemetry.record('revert', {'count': safeIds.length});
      } catch (_) {}
    } finally {
      _busy = false;
      _bumpRestoreGen();
      notifyListeners();
    }
  }

  /// 单文件回退：从 [versionId] 的改动里去掉 [relativePath]，合并进 prev，其余文件不动。
  /// 若该版只剩这一条变化，则删除整个版本节点。工作区只同步该文件到「重算后最新 tree」。
  Future<bool> revertSingleFile({
    required String versionId,
    required String relativePath,
  }) async {
    // 非法 id 不进 _loadTree/路径拼接：此前 crafted id 可穿越读写版本库外。
    if (!_isSafeVersionId(versionId)) return false;
    final root = _rootPath;
    final versions = _versionsDir;
    if (root == null || versions == null || _busy) return false;
    // 毒化 path 不得经回退入口操作区外文件。
    if (!_isSafeRestoreRel(root, relativePath)) return false;
    final index = _checkpoints.indexWhere((e) => e.id == versionId);
    if (index < 0) return false;

    _busy = true;
    // R6-01：单文件/单块回退同样推进 restore 世代，写盘侧排队可见。
    _bumpRestoreGen();
    notifyListeners();
    // 高风险前 push：开启时先推远端，失败只记日志不抛错。
    try {
      if (await GitAnchor.prefsPushBeforeRisky()) {
        final pushed = await GitAnchor.maybePushBeforeRisky(root);
        if (!pushed) {
          AppLogger.instance.warn('checkpoint', '单文件回退前 push 失败，继续本地回退');
        }
      }
    } catch (_) {}
    final safetyId = await _safetyCheckpointIfDrifted(allowBusyOwner: true);
    try {
      final changesBefore = await changesOf(versionId);
      if (!changesBefore.any((c) => c.path == relativePath)) {
        return false;
      }

      final tree = await _loadTree(versionId);
      final prevId = previousVersionId(versionId);
      final prevTree = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);

      // 该版 tree：该 path 改回 prev（等于从本版 diff 里拿掉）
      final newTree = Map<String, String>.from(tree);
      if (prevTree.containsKey(relativePath)) {
        newTree[relativePath] = prevTree[relativePath]!;
      } else {
        newTree.remove(relativePath);
      }

      final changes = await _materializeDiffs(
        changes: _diffTrees(prevTree, newTree),
        prevFiles: prevTree,
        currentFiles: newTree,
        prevId: prevId,
      );

      if (changes.isEmpty) {
        await _deleteVersionArtifacts(versionId);
        _checkpoints.removeWhere((e) => e.id == versionId);
      } else {
        await _writeTree(versionId, newTree);
        final diffFile = File(
          p.join(versions.path, 'diffs', '$versionId.json'),
        );
        await _writeFileAtomic(
          diffFile,
          jsonEncode({
            'id': versionId,
            'prevId': prevId,
            'changes': changes.map((e) => e.toJson()).toList(),
          }),
        );
        _diffCache[versionId] = changes;
        _boundVersionCaches();
        final still = _checkpoints.indexWhere((e) => e.id == versionId);
        if (still >= 0) {
          final old = _checkpoints[still];
          _checkpoints[still] = CheckpointInfo(
            id: old.id,
            message: old.message,
            createdAt: old.createdAt,
            kind: old.kind,
            files: changes.map((e) => e.path).toList(),
            chatId: old.chatId,
            // D7-6：git 元信息透传，重建节点不得丢。
            gitBranch: old.gitBranch,
            gitCommit: old.gitCommit,
            gitDirty: old.gitDirty,
          );
        }
      }

      await _relinkDiffs();
      await _saveManifest();
      // 单文件回退重写 tree/diff 后旧 blob 失引，顺手 GC，避免长期残留。
      try {
        await gcBlobs();
      } catch (_) {}

      await _syncPathToLatest(relativePath, excludeId: safetyId);

      notifyListeners();
      return true;
    } finally {
      _busy = false;
      _bumpRestoreGen();
      notifyListeners();
    }
  }

  /// 单块回退：只撤销 [versionId] 里 [relativePath] 的第 [hunkIndex] 个变更块，
  /// 其余块保留。hunkIndex 按 unified diff 里连续加减行分组从 0 计数，与对话差异页一致。
  /// 若回退后该文件与上一版完全一致，则该文件从本版改动里拿掉（可能删整个节点）。
  Future<bool> revertSingleHunk({
    required String versionId,
    required String relativePath,
    required int hunkIndex,
  }) async {
    if (!_isSafeVersionId(versionId)) return false;
    final root = _rootPath;
    final versions = _versionsDir;
    if (root == null || versions == null || _busy) return false;
    if (!_isSafeRestoreRel(root, relativePath)) return false;
    if (_checkpoints.indexWhere((e) => e.id == versionId) < 0) return false;
    _busy = true;
    // R6-01：单块回退同样推进 restore 世代。
    _bumpRestoreGen();
    notifyListeners();
    final safetyIdHunk = await _safetyCheckpointIfDrifted(allowBusyOwner: true);
    try {
      final newContent = await fileContentAt(versionId, relativePath);
      if (newContent == null) return false;
      final prevId = previousVersionId(versionId);
      final oldContent = prevId == null
          ? ''
          : (await fileContentAt(prevId, relativePath) ?? '');
      if (oldContent == newContent) return false;

      final a = oldContent.split('\n');
      final b = newContent.split('\n');
      // 第1轮R3-1续：大文件单块回退同样设门禁——此前直调_lcsTable，
      // 2MB约40k行即1.6B格OOM。超限直接拒单块回退走整文件回退，不OOM。
      if (a.length * b.length > 4 * 1000 * 1000) return false;
      final lcs = _lcsTable(a, b);
      var i = a.length;
      var j = b.length;
      final ops = <String>[];
      while (i > 0 || j > 0) {
        if (i > 0 && j > 0 && a[i - 1] == b[j - 1]) {
          ops.add(' ${a[i - 1]}');
          i--;
          j--;
        } else if (j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j])) {
          ops.add('+${b[j - 1]}');
          j--;
        } else if (i > 0) {
          ops.add('-${a[i - 1]}');
          i--;
        } else {
          break;
        }
      }
      final ordered = ops.reversed.toList();
      // 分组规则必须与 _lineDiffText 生成一致：<7 行上下文的相邻变更合并为一块，
      // 否则 diff_view 侧按"裸连续 +/-"分组会把该块再拆小，hunkIndex 错位。
      final runs = <List<int>>[];
      var k = 0;
      while (k < ordered.length) {
        if (!(ordered[k].startsWith('+') || ordered[k].startsWith('-'))) {
          k++;
          continue;
        }
        final s = k;
        while (k < ordered.length) {
          final cur = ordered[k];
          if (cur.startsWith('+') || cur.startsWith('-')) {
            k++;
            continue;
          }
          // 上下文：统计连续空格数，<7 且后面还有变更则并入本块继续。
          var spaces = 0;
          var look = k;
          while (look < ordered.length && ordered[look].startsWith(' ')) {
            spaces++;
            look++;
          }
          if (spaces < 7 &&
              look < ordered.length &&
              (ordered[look].startsWith('+') ||
                  ordered[look].startsWith('-'))) {
            k = look;
            continue;
          }
          break;
        }
        runs.add([s, k]);
      }
      if (hunkIndex < 0 || hunkIndex >= runs.length) return false;
      final s = runs[hunkIndex][0];
      final e = runs[hunkIndex][1];
      final out = <String>[];
      for (var t = 0; t < ordered.length; t++) {
        final op = ordered[t];
        if (t >= s && t < e) {
          // 目标块：留旧删新
          if (op.startsWith(' ') || op.startsWith('-')) {
            out.add(op.substring(1));
          }
        } else {
          // 其它块：保持新文件
          if (op.startsWith(' ') || op.startsWith('+')) {
            out.add(op.substring(1));
          }
        }
      }
      final revertedText = out.join('\n');
      if (revertedText == newContent) return false;

      final tree = await _loadTree(versionId);
      final prevTree = prevId == null
          ? <String, String>{}
          : await _loadTree(prevId);
      final newTree = Map<String, String>.from(tree);
      if (revertedText == oldContent) {
        if (prevTree.containsKey(relativePath)) {
          newTree[relativePath] = prevTree[relativePath]!;
        } else {
          newTree.remove(relativePath);
        }
      } else {
        newTree[relativePath] = sha1
            .convert(utf8.encode(revertedText))
            .toString();
      }

      final changes = await _materializeDiffs(
        changes: _diffTrees(prevTree, newTree),
        prevFiles: prevTree,
        currentFiles: newTree,
        prevId: prevId,
        currentId: versionId,
        currentTexts: {relativePath: revertedText},
      );

      if (changes.isEmpty) {
        await _deleteVersionArtifacts(versionId);
        _checkpoints.removeWhere((e) => e.id == versionId);
      } else {
        await _writeTree(versionId, newTree);
        final diffFile = File(
          p.join(versions.path, 'diffs', '$versionId.json'),
        );
        await _writeFileAtomic(
          diffFile,
          jsonEncode({
            'id': versionId,
            'prevId': prevId,
            'changes': changes.map((e) => e.toJson()).toList(),
          }),
        );
        _diffCache[versionId] = changes;
        _boundVersionCaches();
        final still = _checkpoints.indexWhere((e) => e.id == versionId);
        if (still >= 0) {
          final old = _checkpoints[still];
          _checkpoints[still] = CheckpointInfo(
            id: old.id,
            message: old.message,
            createdAt: old.createdAt,
            kind: old.kind,
            files: changes.map((e) => e.path).toList(),
            chatId: old.chatId,
            // D7-6：git 元信息透传，重建节点不得丢。
            gitBranch: old.gitBranch,
            gitCommit: old.gitCommit,
            gitDirty: old.gitDirty,
          );
        }
      }

      await _relinkDiffs();
      await _saveManifest();
      // 单块回退同样清失引 blob。
      try {
        await gcBlobs();
      } catch (_) {}

      await _syncPathToLatest(relativePath, excludeId: safetyIdHunk);

      notifyListeners();
      return true;
    } finally {
      _busy = false;
      _bumpRestoreGen();
      notifyListeners();
    }
  }

  Future<void> clearAll() async {
    // D7-4：在途 restore/checkpoint 时拒绝清库——先于任何删除动作，
    // 否则版本库在恢复中途被整目录删除，_commitOps 继续执行旧 ops。
    if (_busy) throw StateError('版本操作进行中，请稍后再试');
    final versions = _versionsDir;
    if (versions != null && await versions.exists()) {
      await versions.delete(recursive: true);
    }
    // R8-01：清版本库是恢复类写盘终态，推进世代唤醒写盘侧排队者，
    // 否则排队者卡满 30s 超时才放行。
    _bumpRestoreGen();
    notifyListeners();
    await bindProject(_rootPath);
  }

  /// 某对话关联的全部版本节点（含 chatId 匹配）。
  Set<String> versionIdsForChat(String chatId) {
    final ids = <String>{};
    for (final cp in _checkpoints) {
      if (cp.chatId == chatId) ids.add(cp.id);
    }
    return ids;
  }
}

class _FilePayload {
  const _FilePayload({this.text, this.bytes, required this.binary});

  final String? text;
  final List<int>? bytes;
  final bool binary;
}

class _WsOp {
  _WsOp.write(this.rel, this.bytes) : delete = false;
  _WsOp.delete(this.rel) : bytes = null, delete = true;

  final String rel;
  final List<int>? bytes;
  final bool delete;

  /// stage 侧车实际路径：唯一名，避免两次 _stagingPath 调用生成不同名。
  String? stagedTmp;
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
