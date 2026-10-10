import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'checkpoint_store.dart';

/// git 锚点命名 commit + 高风险前 push（默认关闭、本地执行、失败不阻断）。
class GitAnchor {
  /// 是否开启自动锚点 commit（默认关闭）。
  static Future<bool> prefsAutoCommit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('gitAnchorAutoCommit') == true;
    } catch (_) {
      return false;
    }
  }

  /// 高风险操作前是否先 push（默认关闭）。
  static Future<bool> prefsPushBeforeRisky() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('gitPushBeforeRisky') == true;
    } catch (_) {
      return false;
    }
  }

  /// git 调用统一加 `-c safe.directory=*`，沙箱/CI 下属主不一致时不被拒绝。
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
      ]).timeout(const Duration(seconds: 8));
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// message 规范化：合 Conventional 口径直接用，否则 `chore:` 兜底并截断 100 字。
  static String _normalizeMessage(String message) {
    var m = message.trim();
    if (m.isEmpty) m = 'checkpoint';
    if (!CheckpointInfo.isConventionalMessageForTest(m)) {
      m = 'chore: $m';
    }
    if (m.length > 100) m = m.substring(0, 100);
    return m;
  }

  /// 未开启/非 git 仓库直接返回 null；成功返回 commit sha，失败返回 null。
  static Future<String?> maybeAnchorCommit(String root, String message) async {
    try {
      if (!await prefsAutoCommit()) return null;
      if (!await _isGitRepo(root)) return null;
      final msg = _normalizeMessage(message);
      final addRes = await Process.run('git', [
        ..._gitBase(),
        'add',
        '-A',
      ], workingDirectory: root).timeout(const Duration(seconds: 8));
      if (addRes.exitCode != 0) return null;
      final commitRes = await Process.run('git', [
        ..._gitBase(),
        'commit',
        '-m',
        msg,
      ], workingDirectory: root).timeout(const Duration(seconds: 8));
      if (commitRes.exitCode != 0) return null;
      final shaRes = await Process.run('git', [
        ..._gitBase(),
        'rev-parse',
        'HEAD',
      ], workingDirectory: root).timeout(const Duration(seconds: 8));
      if (shaRes.exitCode != 0) return null;
      final sha = '${shaRes.stdout ?? ''}'.trim();
      return sha.isEmpty ? null : sha;
    } catch (_) {
      return null;
    }
  }

  /// 未开启直接 false；否则 git push，成功 true 失败 false。
  static Future<bool> maybePushBeforeRisky(String root) async {
    try {
      if (!await prefsPushBeforeRisky()) return false;
      if (!await _isGitRepo(root)) return false;
      final res = await Process.run('git', [
        ..._gitBase(),
        'push',
      ], workingDirectory: root).timeout(const Duration(seconds: 15));
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
