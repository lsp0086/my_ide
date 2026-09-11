import 'dart:io';

import 'package:path/path.dart' as p;

/// 统一文件门禁：基准 = 当前工作区根目录。
/// - 区内：可读可写，直放
/// - 区外：默认拒绝，需要走审批由调用方弹窗
/// - 系统敏感路径：即使在区内也拒绝（防 Agent 写出 .ssh、git hooks 等逃逸）
class WorkspaceFs {
  WorkspaceFs({required this.rootPath});

  final String rootPath;

  /// 归一化并判定路径位置。
  FsZone zoneOf(String rawPath) {
    final abs = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    final root = p.normalize(rootPath);
    if (abs == root || p.isWithin(root, abs)) {
      final rel = p.relative(abs, from: root);
      if (_isSensitiveRel(rel)) return FsZone.sensitive;
      return FsZone.inside;
    }
    return FsZone.outside;
  }

  String resolveInside(String rawPath) {
    final zone = zoneOf(rawPath);
    if (zone != FsZone.inside) {
      throw FsDeniedException(rawPath, zone);
    }
    final abs = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
    return abs;
  }

  Future<String> readText(String rawPath) async {
    final abs = resolveInside(rawPath);
    return File(abs).readAsString();
  }

  Future<void> writeText(String rawPath, String content) async {
    final abs = resolveInside(rawPath);
    final file = File(abs);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  static bool _isSensitiveRel(String rel) {
    final lower = rel.toLowerCase();
    const sensitiveNames = [
      '.ssh',
      '.gnupg',
      '.aws',
      '.env',
    ];
    for (final name in sensitiveNames) {
      if (lower == name || lower.startsWith('$name/')) return true;
    }
    // git hooks / vscode tasks 等可执行配置：区内写出要审批
    if (lower.startsWith('.git/hooks/')) return true;
    if (lower == '.vscode/settings.json' ||
        lower == '.vscode/tasks.json' ||
        lower == '.vscode/launch.json') {
      return true;
    }
    return false;
  }
}

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

/// 命令沙箱判定：基准同样是工作区。
/// - 白名单只读命令：直放
/// - 高危：直接拒绝
/// - 其余：需审批（弹窗显示完整命令+工作区）
class CommandPolicy {
  static const _dangerous = [
    'rm -rf',
    'rm -fr',
    ':(){',
    'mkfs',
    'dd if=',
    'shutdown',
    'reboot',
    'halt',
    'poweroff',
    '> /dev/',
    'chmod -R 777 /',
    'chown -R',
    'curl',
    'wget',
  ];

  static const _safePrefixes = [
    'ls',
    'pwd',
    'echo',
    'cat',
    'head',
    'tail',
    'wc',
    'git status',
    'git diff',
    'git log',
    'git branch',
    'dart analyze',
    'flutter analyze',
    'flutter --version',
    'dart --version',
    'go version',
    'node --version',
    'npm --version',
    'python --version',
  ];

  static CommandVerdict judge(String command) {
    final lower = command.toLowerCase();
    if (_dangerous.any(lower.contains)) {
      return CommandVerdict.deny;
    }
    final trimmed = command.trim();
    if (_safePrefixes.any(trimmed.startsWith)) {
      return CommandVerdict.allow;
    }
    return CommandVerdict.approve;
  }
}

enum CommandVerdict { allow, approve, deny }
