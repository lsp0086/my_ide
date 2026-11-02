part of 'skill_manager.dart';

/// 加载域：Skill 目录/文件解析与目录拷贝；
/// 路径安全纯函数（原 private static）转同库顶层函数。
extension _SkillManagerScanExt on SkillManager {
Future<AgentSkill?> _tryLoadSkillDir(
  Directory dir, {
  required SkillScope scope,
  required String sourceLabel,
}) async {
  final skillMd = File(p.join(dir.path, 'SKILL.md'));
  if (!await skillMd.exists()) {
    // 兼容 skill.md
    final alt = File(p.join(dir.path, 'skill.md'));
    if (!await alt.exists()) return null;
    return _loadFromFile(
      alt,
      dir: dir,
      scope: scope,
      sourceLabel: sourceLabel,
    );
  }
  return _loadFromFile(
    skillMd,
    dir: dir,
    scope: scope,
    sourceLabel: sourceLabel,
  );
}

Future<AgentSkill?> _loadFromFile(
  File file, {
  required Directory dir,
  required SkillScope scope,
  required String sourceLabel,
}) async {
  try {
    // R-SKILL-LINK：SKILL.md 文件级符号链接 fail-closed——scanRoot 只拒
    // 目录链接与顶层 Link 条目，目录内的 `SKILL.md -> /etc/xxx` 文件链接
    // 此前被 readAsString 跟随，把区外任意文件内容读进 skill body
    // （与 rules_hooks 项目规则拒链接注入同口径）。
    if (FileSystemEntity.isLinkSync(file.path) ||
        FileSystemEntity.isLinkSync(dir.path)) {
      debugPrint('Skill is symlink, skip ${file.path}');
      return null;
    }
    // 大文件门禁：SKILL.md 先 stat，超 1MB 即拒载（8000 截断在拼接后，
    // 无门禁时大文件全量进内存可 OOM）。
    try {
      if (await file.length() > 1024 * 1024) {
        debugPrint('Skill too large, skip ${file.path}');
        return null;
      }
    } catch (_) {}
    final raw = await file.readAsString();
    final parsed = SkillMdParser.parse(
      raw,
      directoryName: p.basename(dir.path),
      // B3-8：严格模式下不合规 skill 抛错被下方 catch 记为跳过原因，
      // 不再告警放行。
      strict: _strictParse,
    );
    return AgentSkill(
      name: parsed.name,
      description: parsed.description,
      body: parsed.body,
      directoryPath: dir.path,
      skillMdPath: file.path,
      scope: scope,
      sourceLabel: sourceLabel,
      license: parsed.license,
      compatibility: parsed.compatibility,
      version: parsed.version,
      author: parsed.author,
      metadata: parsed.metadata,
      allowedTools: parsed.allowedTools,
      parseWarning: parsed.warning,
    );
  } catch (e) {
    debugPrint('Skill load failed ${file.path}: $e');
    return null;
  }
}

Future<void> _copyDir(Directory src, Directory dest) async {
  await dest.create(recursive: true);
  // R3-3 导入总量门禁：SKILL.md 的 1MB 门禁只护入口文件，恶意/误选
  // 超大目录（node_modules 等）递归拷贝无界即卡死/撑爆磁盘。
  // 单文件 >64MB、累计 >2000 文件或 >256MB 即中止（agentskills.io
  // 无上限规范 + VS Code 扩展安装大小先例口径）。
  var files = 0;
  var totalBytes = 0;
  Future<void> copy(Directory s, Directory d) async {
    await d.create(recursive: true);
    await for (final entity in s.list(recursive: false, followLinks: false)) {
      final name = p.basename(entity.path);
      // 导入跳过外链：copy 语义跟随外链会把区外文件拷入 skills，
      // 此前 Directory/File 分支按实体类型仍会拷贝外链目标内容。
      try {
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
            FileSystemEntityType.link) {
          continue;
        }
      } catch (_) {
        continue;
      }
      if (entity is Directory) {
        await copy(entity, Directory(p.join(d.path, name)));
      } else if (entity is File) {
        files++;
        if (files > 2000) {
          throw StateError('skill 目录文件数超过 2000，已中止导入');
        }
        var size = 0;
        try {
          size = await entity.length();
        } catch (_) {}
        if (size > 64 * 1024 * 1024) {
          throw StateError('skill 含超过 64MB 的单文件「$name」，已中止导入');
        }
        totalBytes += size;
        if (totalBytes > 256 * 1024 * 1024) {
          throw StateError('skill 目录总大小超过 256MB，已中止导入');
        }
        await entity.copy(p.join(d.path, name));
      }
    }
  }

  await copy(src, dest);
}
}

/// D9：系统敏感目录判定（UI 添加侧）——根、未展开 ~、系统前缀一律拒。
bool _isSystemForbiddenDir(String normalized) {
  final t = p.normalize(normalized).replaceAll('\\', '/');
  if (t == '/' || t.isEmpty) return true;
  if (t.startsWith('~')) return true;
  const forbidden = <String>[
    '/etc', '/usr', '/bin', '/sbin', '/boot', '/dev', '/proc', '/sys',
    '/opt', '/System', '/Library', '/private/etc', '/private/usr',
    '/private/var/log', '/private/var/db', '/private/var/root',
    '/Windows', '/Program Files', '/Program Files (x86)',
    '/var/log', '/var/db', '/var/root',
  ];
  for (final f in forbidden) {
    if (t == f || t.startsWith('$f/')) return true;
  }
  return false;
}

bool _hasDotDotSegment(String path) {
  for (final seg in path.split('/')) {
    if (seg == '..') return true;
  }
  return false;
}

/// 在 SKILL.md frontmatter 的 metadata 块注入 `mcp-server` 与
/// `mcp-skill-uri` 行；无 metadata 块则在 frontmatter 末尾追加。两个值
/// 均以 JSON 字符串字面量写入（冒号/换行/引号安全）。已有同名键时保持
/// 原值不覆写。
String _injectMcpOrigin(String raw, String serverName, String skillUri) {
  final text = raw.replaceFirst(RegExp(r'^\uFEFF'), '');
  final match = RegExp(
    r'^---\r?\n([\s\S]*?)\r?\n---',
  ).firstMatch(text);
  if (match == null) return raw;
  final front = match.group(1) ?? '';
  final hasOrigin =
      RegExp(r'^\s*mcp-server\s*:', multiLine: true).hasMatch(front);
  final hasUri =
      RegExp(r'^\s*mcp-skill-uri\s*:', multiLine: true).hasMatch(front);
  if (hasOrigin && hasUri) return raw;
  final quotedServer = jsonEncode(serverName);
  final quotedUri = jsonEncode(skillUri);
  final metaLine =
      RegExp(r'^metadata\s*:\s*$', multiLine: true).firstMatch(front);
  final String nextFront;
  if (metaLine != null) {
    final added = StringBuffer(metaLine.group(0)!);
    if (!hasOrigin) added.writeln('\n  mcp-server: $quotedServer');
    if (!hasUri) added.writeln('\n  mcp-skill-uri: $quotedUri');
    nextFront = front.replaceFirst(metaLine.group(0)!, added.toString().trimRight());
  } else {
    nextFront = '$front\nmetadata:\n'
        '${hasOrigin ? '' : '  mcp-server: $quotedServer\n'}'
        '${hasUri ? '' : '  mcp-skill-uri: $quotedUri'}';
  }
  return text.replaceFirst(
    RegExp(r'^---\r?\n[\s\S]*?\r?\n---'),
    '---\n$nextFront\n---',
  );
}
