part of 'workspace_fs.dart';

enum FsZone {
  /// 工作区内：直放
  inside,

  /// 工作区外：需审批
  outside,

  /// 敏感路径：即使在区内也要审批/拒绝
  sensitive,
}

class FsDeniedException implements Exception {
  FsDeniedException(this.path, this.zone);

  final String path;
  final FsZone zone;

  @override
  String toString() {
    if (zone == FsZone.sensitive) {
      return '敏感路径需审批：$path';
    }
    return '工作区外路径需审批：$path';
  }
}

enum CommandVerdict { allow, approve, deny }

class SafeCommandInvocation {
  const SafeCommandInvocation(
    this.executable,
    this.arguments, {
    this.redirectCommand,
  });

  final String executable;
  final List<String> arguments;

  /// A7：非空时命令含区内重定向，必须以 shell 执行该原文
  /// （executable/arguments 是剥离重定向后的核心 argv，直跑会丢重定向）。
  final String? redirectCommand;
}
