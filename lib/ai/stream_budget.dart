import 'dart:async';

/// 流式请求的时间与内存上限。超限抛错，调用方必须关连接。
class StreamBudget {
  StreamBudget({
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 45),
    this.totalDeadline = const Duration(minutes: 5),
    this.maxLineBytes = 256 * 1024,
    this.maxBufferBytes = 1024 * 1024,
    this.maxToolArgsBytes = 256 * 1024,
    this.maxErrorBytes = 64 * 1024,
    this.maxTotalBytes = 8 * 1024 * 1024,
  });

  final Duration connectTimeout;
  final Duration idleTimeout;
  final Duration totalDeadline;
  final int maxLineBytes;
  final int maxBufferBytes;
  final int maxToolArgsBytes;
  final int maxErrorBytes;
  final int maxTotalBytes;

  var totalBytes = 0;
  final DateTime startedAt = DateTime.now();

  void addBytes(int n) {
    totalBytes += n;
    if (totalBytes > maxTotalBytes) {
      throw StateError('响应累计超过 $maxTotalBytes 字节');
    }
    if (DateTime.now().difference(startedAt) > totalDeadline) {
      throw TimeoutException('流总时限已到');
    }
  }

  void checkBuffer(int n) {
    if (n > maxBufferBytes) {
      throw StateError('未换行缓冲超过 $maxBufferBytes 字节');
    }
  }

  void checkLine(int n) {
    if (n > maxLineBytes) {
      throw StateError('单行超过 $maxLineBytes 字节');
    }
  }

  void checkToolArgs(int n) {
    if (n > maxToolArgsBytes) {
      throw StateError('工具参数超过 $maxToolArgsBytes 字节');
    }
  }

  String clipError(String raw) {
    if (raw.length <= maxErrorBytes) return raw;
    return raw.substring(0, maxErrorBytes);
  }
}

/// 给字节流加上空闲超时：超过 [idle] 没有新数据就报错。
Stream<List<int>> withIdleTimeout(
  Stream<List<int>> source,
  Duration idle,
) {
  return source.timeout(
    idle,
    onTimeout: (sink) {
      sink.addError(TimeoutException('流空闲超时'));
      sink.close();
    },
  );
}
