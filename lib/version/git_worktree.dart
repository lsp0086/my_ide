import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'checkpoint_store.dart';

/// worktree 隔离（默认关闭）。
class GitWorktree {
  /// 是否开启 worktree 自动隔离（默认关闭）。
  static Future<bool> prefsAutoIsolate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('agentWorktreeAutoIsolate') == true;
    } catch (_) {
      return false;
    }
  }

  /// 触发隔离的变化文件数阈值：钳制 1~100，默认 10。
  static Future<int> prefsThreshold() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return ((prefs.getInt('agentWorktreeFileThreshold') ?? 10).clamp(1, 100))
          .toInt();
    } catch (_) {
      return 10;
    }
  }

  /// git 调用统一加 `-c safe.directory=*`。
  /// S4-13：只读调用（rev-parse 等）禁用 fsmonitor——防仓主配置的
  /// fsmonitor 集成/hook 在状态查询时执行任意命令。
  static List<String> _gitBase() => [
        '-c',
        'safe.directory=*',
        '-c',
        'core.fsmonitor=false',
      ];

  /// S4-10：带超时收管道的 git 执行——`Process.run(...).timeout` 超时后
  /// 子进程仍存活并挂住管道成为孤儿进程。超时返回 null
  ///（调用方按失败处理，原"失败返回 null/false"语义不变）。
  /// B11：stdout/stderr 有界收集委托 GitSnapshot.runProcessBounded——
  /// 此前 `utf8.decoder.bind(stdout).join()` 无界 join，异常仓库输出可灌爆内存。
  static Future<ProcessResult?> _runGitWithTimeout(
    List<String> args, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    return GitSnapshot.runProcessBounded('git', args, timeout: timeout);
  }

  /// 是否为 git 仓库。
  static Future<bool> _isGitRepo(String root) async {
    try {
      final res = await _runGitWithTimeout([
        ..._gitBase(),
        '-C',
        root,
        'rev-parse',
        '--is-inside-work-tree',
      ]);
      return res != null && res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 标签清洗：只留分支名安全字符，超长截断。
  static String _safeLabel(String label) {
    var s = label.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-');
    s = s.replaceAll(RegExp(r'-{2,}'), '-');
    s = s.replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
    if (s.isEmpty) return 'backup';
    return s.length > 32 ? s.substring(0, 32) : s;
  }

  /// 分支是否存在。
  static Future<bool> _branchExists(String root, String branch) async {
    try {
      final res = await _runGitWithTimeout([
        ..._gitBase(),
        '-C',
        root,
        'rev-parse',
        '--verify',
        '--quiet',
        branch,
      ]);
      return res != null && res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 在 HEAD 建备份分支 `backup/<日期>-<label>`，重名加 -1/-2 后缀，返回分支名。
  /// 非仓库返回 null。
  static Future<String?> ensureBackupBranch(String root, String label) async {
    try {
      if (!await _isGitRepo(root)) return null;
      final now = DateTime.now();
      final date =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final base = 'backup/$date-${_safeLabel(label)}';
      var name = base;
      // B13：off-by-one 修正——旧上限 20 时 base-20 从未被探测：i==20 分支
      // 先赋名 base-20 再立即 return null，base-20 分支名永远分配不到。
      // 上限改 21 后探测覆盖 base 与 base-1..base-20 全部 21 个名字。
      for (var i = 1; i <= 21; i++) {
        if (!await _branchExists(root, name)) break;
        name = '$base-$i';
        if (i == 21) return null;
      }
      final res = await _runGitWithTimeout([
        ..._gitBase(),
        '-C',
        root,
        'branch',
        name,
        'HEAD',
      ]);
      return res != null && res.exitCode == 0 ? name : null;
    } catch (_) {
      return null;
    }
  }
}
