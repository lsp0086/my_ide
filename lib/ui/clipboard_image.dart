import 'dart:convert';
import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

class PastedImage {
  const PastedImage({
    required this.bytes,
    required this.mime,
    required this.dataUrl,
  });

  final Uint8List bytes;
  final String mime;
  final String dataUrl;
}

/// 从剪贴板读取图片：优先位图，其次文件路径文本。
Future<PastedImage?> readClipboardImage() async {
  // 1) 位图（截图 / 复制图片）
  try {
    final bytes = await FlutterClipboard.pasteImage();
    if (bytes != null && bytes.isNotEmpty && bytes.length <= 8 * 1024 * 1024) {
      final mime = _guessMime(bytes);
      return PastedImage(
        bytes: bytes,
        mime: mime,
        dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
      );
    }
  } catch (_) {}

  // 2) macOS 原生兜底：osascript 取 PNG
  if (Platform.isMacOS) {
    final native = await _macPasteboardPng();
    if (native != null) return native;
  }

  // 3) 文本路径 / file://
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return null;
    if (!(text.startsWith('file://') ||
        text.endsWith('.png') ||
        text.endsWith('.jpg') ||
        text.endsWith('.jpeg') ||
        text.endsWith('.webp') ||
        text.endsWith('.gif'))) {
      return null;
    }
    final path =
        text.startsWith('file://') ? Uri.parse(text).toFilePath() : text;
    final f = File(path);
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;
    final mime = _mimeFromPath(path);
    return PastedImage(
      bytes: Uint8List.fromList(bytes),
      mime: mime,
      dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
    );
  } catch (_) {
    return null;
  }
}

String _guessMime(List<int> bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return 'image/png';
}

String _mimeFromPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  return 'image/jpeg';
}

Future<PastedImage?> _macPasteboardPng() async {
  try {
    final tmp = await Directory.systemTemp.createTemp('my_ide_paste_');
    final out = p.join(tmp.path, 'clip.png');
    // 优先 AppKit：截图/复制图片通常是 PNG
    final py = await Process.run('python3', [
      '-c',
      r'''
import sys
try:
  from AppKit import NSPasteboard, NSPasteboardTypePNG, NSPasteboardTypeTIFF
except Exception:
  sys.exit(2)
pb = NSPasteboard.generalPasteboard()
data = pb.dataForType_(NSPasteboardTypePNG)
if data is None:
  data = pb.dataForType_(NSPasteboardTypeTIFF)
if data is None:
  sys.exit(1)
open(sys.argv[1], "wb").write(bytes(data))
''',
      out,
    ]);
    if (py.exitCode != 0) {
      final escaped = out.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      final result = await Process.run('osascript', [
        '-e',
        'try',
        '-e',
        'set theImage to the clipboard as «class PNGf»',
        '-e',
        'set theFile to open for access POSIX file "$escaped" with write permission'
            .replaceFirst(r'$escaped', escaped),
        '-e',
        'set eof of theFile to 0',
        '-e',
        'write theImage to theFile',
        '-e',
        'close access theFile',
        '-e',
        'on error',
        '-e',
        'return 1',
        '-e',
        'end try',
      ]);
      if (result.exitCode != 0) {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
        return null;
      }
    }
    final f = File(out);
    if (!await f.exists()) return null;
    final bytes = await f.readAsBytes();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) return null;
    final mime = _guessMime(bytes);
    return PastedImage(
      bytes: Uint8List.fromList(bytes),
      mime: mime,
      dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
    );
  } catch (_) {
    return null;
  }
}
