import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../fs/workspace_fs.dart';
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
  /// S4-13：只读调用（rev-parse/status/diff/log）禁用 fsmonitor——防仓主
  /// 配置的 fsmonitor 集成/hook 在状态查询时执行任意命令；add/commit/push
  /// 同带无害（仅关闭 fsmonitor 集成，不影响写语义）。
  static List<String> _gitBase() => [
        '-c',
        'safe.directory=*',
        '-c',
        'core.fsmonitor=false',
      ];

  /// B13：git 子进程带超时执行，超时即 kill——`Process.run(...).timeout` 超时
  /// 后子进程仍存活并挂住管道成为孤儿进程。超时返回 null（调用方按失败
  /// 处理，原"失败返回 null/false"语义不变）。
  /// B11：stdout/stderr 有界收集委托 GitSnapshot.runProcessBounded——
  /// 此前 `utf8.decoder.bind(stdout).join()` 无界 join，异常仓库输出可灌爆内存。
  static Future<ProcessResult?> _runGit(
    List<String> args, {
    String? workingDirectory,
    required Duration timeout,
  }) async {
    // A4-12：与 GitSnapshot 共用调用计数钩子（测试校验 anchor 复用快照后
    // 子进程调用次数下降；不注入执行）。
    GitSnapshot.recordGitCallForTest('git', args);
    return GitSnapshot.runProcessBounded(
      'git',
      args,
      workingDirectory: workingDirectory,
      timeout: timeout,
    );
  }

  /// 是否为 git 仓库。
  static Future<bool> _isGitRepo(String root) async {
    try {
      final res = await _runGit(
        [
          ..._gitBase(),
          '-C',
          root,
          'rev-parse',
          '--is-inside-work-tree',
        ],
        timeout: const Duration(seconds: 8),
      );
      return res != null && res.exitCode == 0;
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
    // B13：按 rune 截断——substring 按 UTF-16 码元切，中文/emoji 代理对
    // 被切半会产生非法字符。
    if (m.runes.length > 100) m = String.fromCharCodes(m.runes.take(100));
    return m;
  }

  /// 未开启/非 git 仓库直接返回 null；成功返回 commit sha，失败返回 null。
  /// A4-12：[snapshot] 为调用方已捕获的 GitSnapshot（checkpoint 锁内刚跑过
  /// capture）——复用其仓库判定与 status 输出，避免同一 checkpoint 内重复
  /// 起 rev-parse/status 子进程（大仓每次自动 checkpoint 的 git 开销减半）。
  /// 不传时保持原行为（自行探测）。公开 API 仅增可选命名参数，旧调用方
  /// 签名不变。
  static Future<String?> maybeAnchorCommit(
    String root,
    String message, {
    GitSnapshot? snapshot,
  }) async {
    try {
      if (!await prefsAutoCommit()) return null;
      // A4-12：仓库判定复用已捕获快照——快照明确无仓库时直接跳过，
      // 不再重复 rev-parse --is-inside-work-tree。
      if (snapshot != null) {
        if (!snapshot.hasRepo) return null;
      } else if (!await _isGitRepo(root)) {
        return null;
      }
      final msg = _normalizeMessage(message);
      // R-ANCHOR-SENS：add 前按敏感清单逐条排除——此前 `git add -A` 只排除
      // .my_ide，工作区未被 .gitignore 覆盖的 id_rsa/credentials.json 等
      // 会被写进用户 git 历史（开启 autoCommit 后为每轮自动行为）。
      // 以 WorkspaceFs.isSensitiveRelative 单源判定，status 枚举变更文件。
      final excludes = <String>[':(exclude).my_ide'];
      // A4-12：status 结果共享——capture 已取了 -uall 全量状态，此处直接
      // 复用其输出做敏感枚举，不再二次起 status 子进程。共享的是毫秒级
      // 窗口前的快照：窗口内新出现的文件由 `git add -A` 与 .gitignore
      // 兜底（排除清单本身是未忽略敏感文件的额外防线，非唯一防线）。
      // 快照无 status 输出（探测失败/未传快照）时才回落自跑 status。
      String? statusText;
      if (snapshot != null && snapshot.statusOutput != null) {
        statusText = snapshot.statusOutput;
      } else {
        try {
          final st = await _runGit(
            [..._gitBase(), 'status', '--porcelain', '-uall'],
            workingDirectory: root,
            timeout: const Duration(seconds: 8),
          );
          if (st != null && st.exitCode == 0) {
            statusText = '${st.stdout ?? ''}';
          }
        } catch (_) {}
      }
      if (statusText != null) {
        for (final line in statusText.split('\n')) {
          if (line.length < 4) continue;
          var path = line.substring(3).trim();
          if (path.startsWith('"') && path.endsWith('"') && path.length >= 2) {
            path = path.substring(1, path.length - 1);
          }
          final arrow = path.indexOf(' -> ');
          if (arrow > 0) path = path.substring(arrow + 4).trim();
          if (path.isEmpty) continue;
          // 目录条目（rename 源/子目录聚合）：目录本身不判敏感，
          // 其内文件由 -uall 逐条枚举覆盖。
          if (path.endsWith('/')) continue;
          final norm = p.normalize(path).replaceAll('\\', '/');
          if (WorkspaceFs.isSensitiveRelative(norm)) {
            // R-ANCHOR-LITERAL：literal magic 禁用 glob——文件名含
            // * ? [ 时裸 path 会被当模式匹配不到真实文件，敏感文件
            // 漏排除进 git 历史。
            excludes.add(':(exclude,literal)$path');
          }
        }
      }
      final addRes = await _runGit([
        ..._gitBase(),
        'add',
        '-A',
        // B13：pathspec 排除内部目录——防止把版本库/会话/回收站（.my_ide）
        // 带进用户 git 历史，锚点 commit 只反映用户工作区内容。
        '--',
        ...excludes,
      ], workingDirectory: root, timeout: const Duration(seconds: 8));
      if (addRes == null || addRes.exitCode != 0) return null;
      final commitRes = await _runGit(
        [
          ..._gitBase(),
          'commit',
          '-m',
          msg,
        ],
        workingDirectory: root,
        timeout: const Duration(seconds: 8),
      );
      if (commitRes == null || commitRes.exitCode != 0) return null;
      final shaRes = await _runGit(
        [
          ..._gitBase(),
          'rev-parse',
          'HEAD',
        ],
        workingDirectory: root,
        timeout: const Duration(seconds: 8),
      );
      if (shaRes == null || shaRes.exitCode != 0) return null;
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
      final res = await _runGit(
        [
          ..._gitBase(),
          'push',
        ],
        workingDirectory: root,
        timeout: const Duration(seconds: 15),
      );
      return res != null && res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
