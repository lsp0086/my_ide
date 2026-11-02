import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/voice_input.dart';

void main() {
  group('语音输入超时杀进程', () {
    test('短超时返回超时错误且残留进程被杀', () async {
      if (Platform.isWindows) return;
      final dir = await Directory.systemTemp.createTemp('voice-input-');
      addTearDown(() async {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      });
      final wav = File('${dir.path}/probe.wav');
      await wav.writeAsBytes(const [0, 1, 2, 3]);
      // 假 whisper：忽略 TERM 后 exec 变身 sleep 常驻，模拟转写卡死且
      // 阻塞 SIGTERM（trap '' TERM 对 SIGTERM 置 SIG_IGN，exec 后仍继承，
      // 仅发 TERM 收不掉——必须升 SIGKILL）。exec 后进程 cmdline 为
      // `sleep 30`（不再含脚本路径）。pgrep 需唯一标识本用例进程：
      // flutter test 并行跑多个测试文件，lsp 假 npm / command_process_
      // manager 等文件同样产生 'sleep 30'，全局 pgrep 会跨文件误伤——
      // 故复制 /bin/sleep 为本用例专属名字，按该名字匹配。
      final probe = File('${dir.path}/voice-input-sleep-probe');
      await File('/bin/sleep').copy(probe.path);
      final fakeExe = File('${dir.path}/fake-whisper');
      await fakeExe.writeAsString(
        "#!/bin/sh\ntrap '' TERM\nexec '${probe.path}' 30\n",
      );
      await Process.run('chmod', ['+x', fakeExe.path, probe.path]);

      final (success, message) = await VoiceInput.tryLocalWhisper(
        wav.path,
        timeout: const Duration(milliseconds: 300),
        whisperExeForTest: fakeExe.path,
      );
      // 首选超时后会试 faster-whisper（未安装，ProcessException 跳过），
      // 最终文案为超时失败。关键断言：忽略 TERM 的残留 sleep 必须被
      // SIGKILL 收掉，不得成孤儿。
      expect(success, isFalse);
      expect(message, contains('转写超时'));
      // TERM → grace(2s) → KILL 收敛路径需要数秒；给足收尸时间再断言。
      await Future<void>.delayed(const Duration(seconds: 5));
      final ps = await Process.run('pgrep', ['-f', 'voice-input-sleep-probe']);
      expect(
        '${ps.stdout}'.trim(),
        isEmpty,
        reason: '超时 whisper 进程必须被 TERM→KILL 升级收尸杀掉',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
