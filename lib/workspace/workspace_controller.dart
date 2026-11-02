import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/app_logger.dart';
import '../diagnostics/telemetry.dart';
import '../fs/workspace_fs.dart';
import '../settings/settings_store.dart';
part 'workspace_controller_models.dart';
part 'workspace_controller_conflict.dart';
part 'workspace_controller_drafts.dart';
part 'workspace_controller_session.dart';
part 'workspace_controller_workspace.dart';
part 'workspace_controller_watch.dart';
part 'workspace_controller_locks.dart';
part 'workspace_controller_tree.dart';
part 'workspace_controller_files.dart';
part 'workspace_controller_tabs.dart';
part 'workspace_controller_filekind.dart';


class WorkspaceController extends ChangeNotifier {
  static final Random _rng = Random.secure();
  bool _disposed = false;
  String? _rootPath;
  List<WorkspaceFile> _tree = const [];
  final List<OpenEditorTab> _tabs = [];
  String? _activePath;
  String? _selectedPath;
  bool _loadingTree = false;
  bool _pickingFolder = false;
  String? _treeError;
  int _openGeneration = 0;
  /// D4：loadTree 在途序号——await 间隙切项目/重复加载后，旧在途结果
  /// 按序号失配丢弃（写回与在途标记清理同口径）。
  int _treeLoadSeq = 0;
  final Set<String> _dirtyPaths = <String>{};
  /// 外部写入（AI/回退）后递增，驱动已打开编辑器重新读盘。
  int _contentEpoch = 0;
  final Map<String, int> _pathContentEpoch = <String, int>{};
  /// 已知磁盘 mtime（微秒），用于切回应用时检测外部覆盖。
  /// 微秒精度：毫秒截断下同毫秒同大小改写漏检（与 AgentTools 快照对齐）。
  final Map<String, int> _diskMtimeMs = <String, int>{};
  bool _scanningExternal = false;
  /// R-WATCH-DIRTY：burst 扫描期间到达的事件置位，finally 里补一次处理。
  bool _watchDirtyDuringScan = false;
  /// 当前窗口持有的项目锁路径（`.my_ide/project.lock`）。
  String? _heldLockPath;
  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _watchDebounce;
  /// 脏冲突：磁盘已变但本地有未保存缓冲，等待用户抉择，不静默覆盖。
  final Set<String> _conflictPaths = <String>{};
  /// 覆盖确认：冲突选"保留本地"后，下次手动保存前再确认一次
  /// （选对话框和按保存可能隔很久，避免用户忘记而覆盖磁盘改动）。
  final Set<String> _overwriteConfirmPending = <String>{};
  /// 外部冲突回调（UI 侧弹窗抉择）。参数为绝对路径列表。
  void Function(List<String> conflicts)? onExternalConflict;


  String? get rootPath => _rootPath;
  bool get hasWorkspace => _rootPath != null;
  List<WorkspaceFile> get tree => _tree;
  List<OpenEditorTab> get tabs => List.unmodifiable(_tabs);
  String? get activePath => _activePath;
  String? get selectedPath => _selectedPath;
  bool get loadingTree => _loadingTree;
  bool get pickingFolder => _pickingFolder;
  String? get treeError => _treeError;
  /// 每次成功 openFolder 递增，便于同路径重开时强制重新绑定对话/版本。
  int get openGeneration => _openGeneration;
  int get contentEpoch => _contentEpoch;
  bool isDirty(String path) => _dirtyPaths.contains(path);

  /// 某路径的内容世代；外部改写后递增，编辑器用它决定是否 reload。
  int contentEpochOf(String path) => _pathContentEpoch[path] ?? 0;


  /// 编辑器落盘回调注册：CodeEditorPane 挂载时注册，卸载时注销。
  /// 发送前 saveAll 靠它把已挂载编辑器的未保存内容落盘。
  final Map<String, Future<bool> Function()> _saveHandlers = {};

  /// S5：卸载时暂存的未保存缓冲。编辑器切走 tab（pane 卸载）时若有
  /// 未保存内容，缓冲随 controller 一起销毁；暂存到这里后，
  /// 下次挂载 _load 优先恢复，避免"显示脏但内容已是磁盘版"的不一致。
  /// 进程内有效；崩溃丢失由周期自动保存兜底。
  final Map<String, String> _draftBuffers = {};


  /// R17-05（A4-9）：侧车草稿大小上限——读回侧超过即判损坏不载入，
  /// 防半写/截断的坏稿进编辑器（对齐 lsp_client 16MB 档位）。
  static const int _draftSidecarMaxBytes = 16 * 1024 * 1024;



  bool _savingAll = false;


  bool _autosaving = false;


  Timer? _autosaveTimer;


  // ── 会话恢复（W3）：打开的标签随工作区持久化到 .my_ide/session.json ──
  Timer? _sessionSaveDebounce;

  /// 标签集合/激活态变化后防抖落盘，重启打开同一项目时恢复。


  @override
  void dispose() {
    _disposed = true;
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
    _sessionSaveDebounce?.cancel();
    _sessionSaveDebounce = null;
    _stopWatch();
    // 窗口销毁时尽量释放项目锁，避免其它窗口永久打不开。
    final closing = _rootPath;
    if (closing != null) {
      _ProcessProjectLocks.release(closing, this);
    }
    unawaited(_releaseProjectLock());
    super.dispose();
  }

  /// 分域 part 桥接：extension 内不可直接调用受 @protected 的 notifyListeners。
  void notifyWorkspaceChanged() => notifyListeners();


  /// 外部变更可靠通道：Directory.watch 递归监听 + mtime 二次确认。
  /// 只做"发现"，落盘抉择仍走 mtime 对比；.my_ide 自写目录直接忽略防回环。
  /// E8-WATCH-HEALTH：watch error 不再静默吞——错误即重建监听 + 全量
  /// mtime 重扫兜底（来源 Zed #38109 外部改动失步问题
  /// https://github.com/zed-industries/zed/issues/38109 ，采纳错误重建与
  /// 轮询兜底、不采纳其 pollwatcher 常态化轮询）；重建退避 2s/10s/30s 封顶。
  int _watchRestartAttempts = 0;


  /// watch burst 处理完成后通知 UI 做 drift 快照。
  /// checkpoint() 无变化返回 null，天然去重，高频调用安全；
  /// `.my_ide` 自写目录已被忽略，无回环。
  VoidCallback? onWorkspaceBurst;



  /// R17-04（A4-5）：空锁/脏内容被视为"陈旧"的时间窗——create(exclusive)
  /// 成功后 tmp+rename 写 pid 前崩溃会残留空 project.lock，mtime 超过本
  /// 窗口（10s，远超正常亚秒级写 pid 耗时）即判定为陈旧锁，允许覆盖写
  /// pid；窗口内仍视为"对端创建中"保守拒绝。
  static const Duration _emptyLockStaleWindow = Duration(seconds: 10);

  /// R17-04（A4-5）：空锁陈旧判定纯函数（可注入 now 便于测试）——
  /// 锁文件 ownerPid 解析失败时由 _acquireProjectLock 调用。
  @visibleForTesting
  static bool isEmptyLockStale(DateTime mtime, {DateTime? now}) {
    final t = now ?? DateTime.now();
    return t.difference(mtime) > _emptyLockStaleWindow;
  }


  /// D4 测试缝：loadTree 读取目录前钩子（默认 null 零开销）——挂起该
  /// Future 即可模拟慢 _readDirectory，制造"切项目后旧结果才回来"的
  /// 竞态窗口，验证旧在途结果被丢弃。
  @visibleForTesting
  Future<void> Function()? debugTreeReadGate;




  int? _pendingRevealLine;
  int? _pendingRevealColumn;
  String? _pendingRevealPath;



  /// 页面标签页固定路径：同一时刻一个"当前页面"标签，Agent 每次打开即更新它。
  static const browserTabPath = 'browser:page';


  static FileKind detectFileKind(String name, {String? path}) {
    final ext = p.extension(name).toLowerCase();
    if (ext == '.svg') return FileKind.svg;
    if (_imageExtensions.contains(ext)) return FileKind.image;
    if (_textExtensions.contains(ext)) return FileKind.text;
    if (path != null && looksLikeTextFile(path)) return FileKind.text;
    return FileKind.unsupported;
  }

  /// 通过采样内容判断文件是否可作为文本打开。
  static bool looksLikeTextFile(String path, {int sampleSize = 8192}) {
    try {
      final file = File(path);
      if (!file.existsSync()) return false;

      final length = file.lengthSync();
      if (length == 0) return true;

      final raf = file.openSync();
      try {
        final count = length < sampleSize ? length : sampleSize;
        final bytes = raf.readSync(count);
        if (bytes.isEmpty) return true;

        // UTF-8 / UTF-16 BOM
        if (bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF) {
          return true;
        }
        if (bytes.length >= 2 &&
            ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
                (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
          return true;
        }

        var nullCount = 0;
        var controlCount = 0;
        for (final b in bytes) {
          if (b == 0) {
            nullCount++;
            continue;
          }
          final isAllowedControl = b == 9 || b == 10 || b == 13;
          if (b < 32 && !isAllowedControl) {
            controlCount++;
          }
        }

        if (nullCount > bytes.length * 0.01) return false;
        if (controlCount > bytes.length * 0.02) return false;
        return _isValidUtf8(bytes);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }



  /// 大仓上限：prefs `workspaceMaxFiles`，默认 8000；测试可覆盖。
  int? maxFilesOverrideForTest;



}

