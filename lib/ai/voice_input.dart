import 'dart:io';

/// 语音输入：尝试调用本机 whisper / faster-whisper CLI，不新增依赖。
/// CLI 不存在或失败时返回友好提示，由调用方展示。
class VoiceInput {
  /// 尝试用本机 whisper CLI 转写 [wavPath]。
  /// 成功返回 (true, 文本)，失败返回 (false, 友好提示)。
  static Future<(bool, String)> tryLocalWhisper(String wavPath) async {
    final f = File(wavPath);
    if (!await f.exists()) {
      return (false, '音频文件不存在：$wavPath');
    }
    const candidates = <List<String>>[
      ['whisper', '--model', 'base', '--language', 'Chinese', '--output_format', 'txt'],
      ['faster-whisper', '--model', 'base'],
    ];
    for (final cmd in candidates) {
      try {
        final result = await Process.run(
          cmd.first,
          [...cmd.sublist(1), wavPath],
        ).timeout(const Duration(seconds: 120));
        if (result.exitCode == 0) {
          final text = '${result.stdout}'.trim();
          return (true, text.isEmpty ? '（识别结果为空）' : text);
        }
      } catch (_) {
        continue;
      }
    }
    return (
      false,
      '本机未找到可用的 whisper / faster-whisper 命令行工具，'
          '请安装后重试（pip install openai-whisper），或改用文本输入。'
    );
  }
}
