import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../diagnostics/app_logger.dart';
import 'command_process_manager.dart';

/// B2：post-edit lint/test 修复闭环（Aider 口径，
/// 来源 https://aider.chat/docs/usage/lint-test.html）。
///
/// - 配置：项目 `.my_ide/config.json` 的 `postEdit` 字段：
///   `{"postEdit": {"command": "flutter", "args": ["test"], "timeoutSec": 120,
///     "maxRounds": 3}}`；无配置时不执行任何命令。
/// - 语义：turn 收尾且本轮有写文件时执行一次；stdout+stderr 合并裁剪后
///   经 external_content.dart 的 wrapUntrustedToolOutput 围栏化作为下轮
///   观察注入——外部命令输出是数据，不是指令；连续失败超 maxRounds 停止
///   回喂（转人工）。
/// - 安全：只跑单一白名单命令（无 shell，args 直传，防注入拼接）；
///   工作目录锁定项目根；超时强杀进程。
class PostEditConfig {
  PostEditConfig({
    required this.command,
    this.args = const [],
    this.timeoutSec = 120,
    this.maxRounds = 3,
  });

  final String command;
  final List<String> args;

  /// 单次执行超时（秒）。
  final int timeoutSec;

  /// 连续失败后停止回喂的轮数上限（0 或负数视为不限）。
  final int maxRounds;

  static PostEditConfig? fromJson(Map<String, dynamic> json) {
    final command = (json['command'] as String?)?.trim() ?? '';
    if (command.isEmpty) return null;
    final rawArgs = json['args'];
    final args = rawArgs is List
        ? rawArgs.map((e) => e.toString()).toList(growable: false)
        : <String>[];
    final timeout = json['timeoutSec'];
    final rounds = json['maxRounds'];
    return PostEditConfig(
      command: command,
      args: args,
      timeoutSec: timeout is int && timeout > 0 ? timeout : 120,
      maxRounds: rounds is int ? rounds : 3,
    );
  }

  Map<String, dynamic> toJson() => {
        'command': command,
        'args': args,
        'timeoutSec': timeoutSec,
        'maxRounds': maxRounds,
      };
}

/// 单次 post-edit 执行结果。
class PostEditRun {
  PostEditRun({
    required this.ran,
    this.exitCode,
    this.timedOut = false,
    this.output = '',
  });

  /// false 表示未跑（无配置等）。
  final bool ran;

  final int? exitCode;
  final bool timedOut;

  /// stdout+stderr 合并、已截断（供围栏化注入）。
  final String output;

  bool get ok => ran && !timedOut && exitCode == 0;

  /// 是否需要回喂（执行了且有内容或失败）。
  bool get needsFeedback => ran && (output.trim().isNotEmpty || !ok);
}

class PostEditGate {
  const PostEditGate();

  /// 输出注入体积钳制：防巨型日志把 prompt 撑爆（与 diff 直通同口径）。
  static const int maxOutputChars = 32000;

  /// 从项目根读配置；文件不存在/解析失败/无 postEdit 字段均返回 null。
  static Future<PostEditConfig?> configFor(String rootPath) async {
    if (rootPath.trim().isEmpty) return null;
    try {
      final file = File(p.join(rootPath, '.my_ide', 'config.json'));
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      final section = decoded['postEdit'];
      if (section is! Map) return null;
      return PostEditConfig.fromJson(Map<String, dynamic>.from(section));
    } catch (e) {
      AppLogger.instance.warn('post-edit', 'postEdit 配置读取失败，本轮跳过', e);
      return null;
    }
  }

  /// 执行配置命令并采集输出。全程不抛错。
  Future<PostEditRun> run({
    required PostEditConfig config,
    required String rootPath,
  }) async {
    // D2：统一走 CommandProcessManager 启停——start 经 childEnvironment
    // 下发 NoDefaultCurrentDirectoryInExePath=1（B9 Windows exe 劫持防护，
    // 此前裸 Process.start 绕开该防护）；超时 terminateWithReport 整树
    // 追杀（pgrep -P 递归后代 + 校验过的进程组杀），不再只杀直接子进程
    // 留下孙进程（sh -c '(...) & wait' 子壳）继续写盘。
    final manager = CommandProcessManager();
    try {
      final proc = await manager.start(
        config.command,
        config.args,
        workingDirectory: rootPath,
      );
      final out = <int>[];
      var truncated = false;
      void pump(List<int> chunk) {
        if (truncated) return;
        final room = maxOutputChars - out.length;
        if (chunk.length >= room) {
          out.addAll(chunk.take(room));
          truncated = true;
        } else {
          out.addAll(chunk);
        }
      }

      final done = Future.wait([
        proc.stdout.forEach(pump),
        proc.stderr.forEach(pump),
        proc.exitCode,
      ]);
      final timedOut = await done
          .then((_) => false)
          .timeout(Duration(seconds: config.timeoutSec), onTimeout: () {
            // D2：超时强杀整棵进程树——孤儿 lint/test 及其孙进程会把
            // 下一轮 post-edit 挂在磁盘上（此前只杀直接子进程，
            // `(...) & wait` 子壳照常写盘）。
            unawaited(manager.terminateWithReport(
              proc,
              gracePeriod: const Duration(milliseconds: 200),
            ));
            return true;
          });
      final code = await proc.exitCode;
      final output = truncated
          ? '${utf8.decode(out, allowMalformed: true)}\n…(输出超过 $maxOutputChars 字符已截断)'
          : utf8.decode(out, allowMalformed: true);
      return PostEditRun(
        ran: true,
        exitCode: code,
        timedOut: timedOut,
        output: output,
      );
    } catch (e) {
      AppLogger.instance.warn('post-edit', 'postEdit 命令执行失败', e);
      return PostEditRun(ran: true, timedOut: false, output: '命令无法执行：$e');
    } finally {
      await manager.dispose();
    }
  }
}
