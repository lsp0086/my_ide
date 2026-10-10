import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

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
  static List<String> _gitBase() => ['-c', 'safe.directory=*'];

  /// 是否为 git 仓库。
  static Future<bool> _isGitRepo(String root) async {
    try {
      final res = await Process.run('git', [
        ..._gitBase(),
        '-C',
        root,
        'rev-parse',
        '--is-inside-work-tree',
      ]).timeout(const Duration(seconds: 10));
      return res.exitCode == 0;
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
      final res = await Process.run('git', [
        ..._gitBase(),
        '-C',
        root,
        'rev-parse',
        '--verify',
        '--quiet',
        branch,
      ]).timeout(const Duration(seconds: 10));
      return res.exitCode == 0;
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
      for (var i = 1; i <= 20; i++) {
        if (!await _branchExists(root, name)) break;
        name = '$base-$i';
        if (i == 20) return null;
      }
      final res = await Process.run('git', [
        ..._gitBase(),
        '-C',
        root,
        'branch',
        name,
        'HEAD',
      ]).timeout(const Duration(seconds: 10));
      return res.exitCode == 0 ? name : null;
    } catch (_) {
      return null;
    }
  }

  /// 在 `<root>/.my_ide/worktrees/<branch-safe>` 建隔离 worktree，返回路径；失败 null。
  static Future<String?> createIsolatedWorktree(
    String root,
    String branch,
  ) async {
    try {
      if (!await _isGitRepo(root)) return null;
      final safe = branch
          .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')
          .replaceAll(RegExp(r'-{2,}'), '-');
      if (safe.isEmpty) return null;
      final wtPath = p.join(root, '.my_ide', 'worktrees', safe);
      final res = await Process.run('git', [
        ..._gitBase(),
        '-C',
        root,
        'worktree',
        'add',
        wtPath,
        branch,
      ]).timeout(const Duration(seconds: 10));
      return res.exitCode == 0 ? wtPath : null;
    } catch (_) {
      return null;
    }
  }

  /// 移除隔离 worktree，吞错。
  static Future<void> removeWorktree(String root, String wtPath) async {
    try {
      await Process.run('git', [
        ..._gitBase(),
        '-C',
        root,
        'worktree',
        'remove',
        '--force',
        wtPath,
      ]).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }
}
