import 'dart:async';

import 'dart:io';

import 'remote_channel.dart' show clipRunes;

/// 语音输入：尝试调用本机 whisper / faster-whisper CLI，不新增依赖。
/// CLI 不存在或失败时返回友好提示，由调用方展示。
class VoiceInput {
  /// 尝试用本机 whisper CLI 转写 [wavPath]。
  /// 成功返回 (true, 文本)，失败返回 (false, 友好提示)。
  /// [timeout] 单条命令转写超时，默认 120s（C16：提为可选参数）。
  ///
  /// C16 失败区分：命令不在 PATH（ProcessException）保持「未找到命令」
  /// 安装提示；其他失败（非零退出/超时等）返回带退出码与 stderr 摘要
  /// （≤200 字）的具体错误文案，不再一律谎报「未找到命令」。
  /// [whisperExeForTest] 测试钩子：覆盖首选候选的可执行路径
  /// （默认 `whisper` 走 PATH 查找，测试传入临时假脚本绝对路径）。
  static Future<(bool, String)> tryLocalWhisper(
    String wavPath, {
    Duration timeout = const Duration(seconds: 120),
    String? whisperExeForTest,
  }) async {
    final f = File(wavPath);
    if (!await f.exists()) {
      return (false, '音频文件不存在：$wavPath');
    }
    // C16：whisper 产物落一次性系统临时目录，转录后读取并整体删除，
    // 不再向当前工作目录残留 <音频名>.txt。
    final outputDir = await Directory.systemTemp.createTemp('voice_input');
    try {
      // （可执行名, 参数, 是否从产物文件读结果）。whisper 的 stdout 多为
      // 进度日志，真结果在 --output_dir 下的 .txt；faster-whisper 直接打 stdout。
      final candidates = <(String, List<String>, bool)>[
        (
          whisperExeForTest ?? 'whisper',
          [
            '--model', 'base', '--language', 'Chinese',
            '--output_format', 'txt', '--output_dir', outputDir.path,
          ],
          true,
        ),
        ('faster-whisper', ['--model', 'base'], false),
      ];
      // C16：最近一次「真实失败」摘要；全候选都 ProcessException（未安装）
      // 时保持旧「未找到命令」文案。
      String? failureDetail;
      for (final (exe, args, fromFile) in candidates) {
        Process? process;
        try {
          // S2-4：持句柄启动替代 Process.run(...).timeout——后者超时只丢弃
          // future，底层 whisper 进程继续常驻孤儿。现超时先 kill 再收尸。
          process = await Process.start(exe, [...args, wavPath]);
          final stdoutFuture =
              process.stdout.transform(const SystemEncoding().decoder).join();
          final stderrFuture =
              process.stderr.transform(const SystemEncoding().decoder).join();
          int exitCode;
          try {
            exitCode = await process.exitCode.timeout(timeout);
          } on TimeoutException {
            // R18-07：TERM 后短 grace 未退出升 SIGKILL——whisper 忽略/阻塞
            // SIGTERM（trap '' TERM 等）时只发 TERM 的收尸失败成孤儿。
            await _reap(process);
            // 杀后收尸/丢弃输出，避免僵尸与流挂死（有限等待，不阻塞）。
            try {
              await Future.wait([stdoutFuture, stderrFuture])
                  .timeout(const Duration(seconds: 5));
            } catch (_) {}
            rethrow;
          }
          final out = await stdoutFuture;
          final err = await stderrFuture;
          final result = ProcessResult(process.pid, exitCode, out, err);
          process = null;
          if (result.exitCode == 0) {
            var text = '${result.stdout}'.trim();
            if (fromFile) {
              try {
                final artifact = File(_artifactPath(wavPath, outputDir.path));
                if (await artifact.exists()) {
                  text = (await artifact.readAsString()).trim();
                }
              } catch (_) {}
            }
            return (true, text.isEmpty ? '（识别结果为空）' : text);
          }
          // C16：非零退出——记录带退出码与 stderr 摘要（≤200 字）的具体错误。
          failureDetail = '${exe.trim()} 退出码 ${result.exitCode}：'
              '${_stderrBrief('${result.stderr}')}';
        } on TimeoutException {
          failureDetail = '转写超时（超过 ${timeout.inSeconds}s）';
        } on ProcessException {
          // 命令不在 PATH（未安装）：继续尝试下一候选，最后统一提示安装。
        } catch (e) {
          failureDetail = '$e';
        } finally {
          // 兜底收尸：启动成功但 exitCode 前抛错（如解码）时杀掉残留进程。
          // R18-07：同样走 TERM→grace→KILL 升级收尸，防阻塞 TERM 成孤儿。
          final pending = process;
          if (pending != null) {
            await _reap(pending);
          }
        }
      }
      if (failureDetail != null) {
        return (
          false,
          '语音转写失败：$failureDetail。请检查音频格式后重试，或改用文本输入。'
        );
      }
      return (
        false,
        '本机未找到可用的 whisper / faster-whisper 命令行工具，'
            '请安装后重试（pip install openai-whisper），或改用文本输入。'
      );
    } finally {
      // C16：临时目录（含 whisper 产物 .txt）整体删除，不留垃圾文件。
      try {
        await outputDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// R18-07：TERM 后短 grace（2s）未退出升 SIGKILL 的收尸——先发 SIGTERM，
  /// 宽限内未退出（whisper 阻塞/忽略 TERM）再升 SIGKILL，最后有限等待
  /// 彻底收尸（exitCode 收敛）。任一步抛错均吞掉保底，不掩盖原失败原因。
  static Future<void> _reap(
    Process process, {
    Duration grace = const Duration(seconds: 2),
  }) async {
    try {
      process.kill();
    } catch (_) {}
    try {
      await process.exitCode.timeout(grace);
      return;
    } catch (_) {}
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// C16：whisper 产物路径——<临时目录>/<音频去扩展名>.txt。
  static String _artifactPath(String wavPath, String dirPath) {
    final sep = Platform.pathSeparator;
    final base = wavPath.split('\\').last.split('/').last;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    return '$dirPath$sep$stem.txt';
  }

  /// C16：stderr 摘要压成单行并按 rune 截到 200 字。
  static String _stderrBrief(String stderr, {int maxRunes = 200}) {
    final oneLine = stderr.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clipRunes(oneLine, maxRunes);
  }
}
