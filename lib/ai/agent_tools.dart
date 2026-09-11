import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../fs/workspace_fs.dart';

/// Agent 文件工具执行：read/write/edit，限制在工作区内。
class AgentToolResult {
  AgentToolResult({
    required this.ok,
    required this.output,
    this.touchedFiles = const [],
    this.preview,
  });

  final bool ok;
  final String output;
  final List<String> touchedFiles;
  final FilePreview? preview;
}

class FilePreview {
  FilePreview({
    required this.path,
    required this.oldContent,
    required this.newContent,
  });

  final String path;
  final String oldContent;
  final String newContent;
}

class AgentTools {
  AgentTools({required this.rootPath})
      : _fs = WorkspaceFs(rootPath: rootPath);

  final String rootPath;
  final WorkspaceFs _fs;

  WorkspaceFs get fs => _fs;

  String _resolve(String relPath) {
    return _fs.resolveInside(relPath);
  }

  String _resolveAny(String rawPath) {
    return p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath),
    );
  }

  Future<AgentToolResult> execute(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'read_file':
        return _read(args);
      case 'write_file':
        return _write(args);
      case 'edit_file':
        return _edit(args);
      case 'delete_file':
        return _delete(args);
      case 'list_files':
        return _list(args);
      case 'search_text':
        return _search(args);
      case 'run_command':
        return _runCommand(args);
      case 'ask_question':
        // 由 Runner 拦截处理，这里兜底
        return AgentToolResult(
            ok: false, output: 'ask_question 需经 UI 确认后继续');
      case 'spawn_subagent':
        return AgentToolResult(
            ok: false, output: 'spawn_subagent 需经 Runner 调度');
      default:
        return AgentToolResult(ok: false, output: '未知工具：$name');
    }
  }

  /// 审批通过后的区外/敏感只读：仅 read_file / list_files。
  Future<AgentToolResult> executeApprovedRead(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'read_file':
        return _read(args, allowOutside: true);
      case 'list_files':
        return _list(args, allowOutside: true);
      default:
        return AgentToolResult(
          ok: false,
          output: '区外/敏感路径审批后仅支持 read_file / list_files',
        );
    }
  }

  /// 只做预览不落盘，供审批弹窗展示 Diff。
  Future<AgentToolResult> preview(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'write_file':
        return _writePreview(args);
      case 'edit_file':
        return _editPreview(args);
      case 'delete_file':
        return _deletePreview(args);
      default:
        return execute(name, args);
    }
  }

  Future<AgentToolResult> _read(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final limit = (args['limit'] as num?)?.toInt() ?? 200;
    final offset = (args['offset'] as num?)?.toInt() ?? 0;
    try {
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > 512 * 1024) {
        return AgentToolResult(
            ok: false, output: '文件过大，拒绝读取：$rel');
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = text.split('\n');
      final start = offset.clamp(0, lines.length);
      final end = (start + limit).clamp(0, lines.length);
      final slice = lines.sublist(start, end).join('\n');
      return AgentToolResult(
        ok: true,
        output:
            '文件 $rel 共 ${lines.length} 行，显示 $start-${end - 1}：\n$slice',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '读取失败：$e');
    }
  }

  Future<AgentToolResult> _write(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}';
    final content = '${args['content'] ?? ''}';
    try {
      final file = File(_resolve(rel));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return AgentToolResult(
        ok: true,
        output: '已写入 $rel（${content.length} 字符）',
        touchedFiles: [rel],
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '写入失败：$e');
    }
  }

  Future<AgentToolResult> _edit(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}';
    final oldText = '${args['oldText'] ?? ''}';
    final newText = '${args['newText'] ?? ''}';
    try {
      final file = File(_resolve(rel));
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      final content = await file.readAsString();
      if (!content.contains(oldText)) {
        return AgentToolResult(
            ok: false,
            output: 'oldText 未精确匹配（含空格），请先 read_file 查看原文');
      }
      final updated = content.replaceFirst(oldText, newText);
      await file.writeAsString(updated);
      return AgentToolResult(
        ok: true,
        output: '已编辑 $rel',
        touchedFiles: [rel],
        preview: FilePreview(
            path: rel, oldContent: content, newContent: updated),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '编辑失败：$e');
    }
  }

  Future<AgentToolResult> _delete(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}';
    try {
      final file = File(_resolve(rel));
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      await file.delete();
      return AgentToolResult(
        ok: true,
        output: '已删除 $rel',
        touchedFiles: [rel],
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '删除失败：$e');
    }
  }

  Future<AgentToolResult> _deletePreview(
      Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}';
    try {
      final file = File(_resolve(rel));
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      final old = await file.readAsString();
      return AgentToolResult(
        ok: true,
        output: '预览删除 $rel（${old.length} 字符）',
        touchedFiles: [rel],
        preview: FilePreview(path: rel, oldContent: old, newContent: ''),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _writePreview(
      Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}';
    final content = '${args['content'] ?? ''}';
    try {
      final file = File(_resolve(rel));
      final old =
          await file.exists() ? await file.readAsString() : '';
      return AgentToolResult(
        ok: true,
        output: '预览 $rel（${content.length} 字符）',
        touchedFiles: [rel],
        preview:
            FilePreview(path: rel, oldContent: old, newContent: content),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _editPreview(
      Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}';
    final oldText = '${args['oldText'] ?? ''}';
    final newText = '${args['newText'] ?? ''}';
    try {
      final file = File(_resolve(rel));
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      final content = await file.readAsString();
      if (!content.contains(oldText)) {
        return AgentToolResult(
            ok: false, output: 'oldText 未精确匹配，请先 read_file');
      }
      final updated = content.replaceFirst(oldText, newText);
      return AgentToolResult(
        ok: true,
        output: '预览编辑 $rel',
        touchedFiles: [rel],
        preview: FilePreview(
            path: rel, oldContent: content, newContent: updated),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _list(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? '.'}';
    try {
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final dir = Directory(abs);
      if (!await dir.exists()) {
        return AgentToolResult(ok: false, output: '目录不存在：$rel');
      }
      final entries = await dir.list(followLinks: false).toList();
      entries.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return p.basename(a.path).compareTo(p.basename(b.path));
      });
      final buf = StringBuffer('目录 $rel：\n');
      for (final e in entries.take(200)) {
        final name = p.basename(e.path);
        if (name.startsWith('.my_ide')) continue;
        buf.writeln(e is Directory ? '$name/' : name);
      }
      return AgentToolResult(ok: true, output: buf.toString());
    } catch (e) {
      return AgentToolResult(ok: false, output: '列目录失败：$e');
    }
  }

  Future<AgentToolResult> _search(Map<String, dynamic> args) async {
    final query = '${args['query'] ?? ''}';
    final include = '${args['include'] ?? ''}';
    if (query.isEmpty) {
      return AgentToolResult(ok: false, output: 'query 不能为空');
    }
    try {
      final results = <String>[];
      final root = Directory(rootPath);
      await for (final entity in root.list(
          recursive: true, followLinks: false)) {
        if (results.length >= 50) break;
        if (entity is! File) continue;
        final rel = p.relative(entity.path, from: rootPath);
        if (rel.startsWith('.my_ide') || rel.startsWith('.git')) {
          continue;
        }
        if (include.isNotEmpty && !rel.endsWith(include)) continue;
        try {
          final bytes = await entity.readAsBytes();
          if (bytes.length > 512 * 1024) continue;
          final text = utf8.decode(bytes, allowMalformed: true);
          final lines = text.split('\n');
          for (var i = 0; i < lines.length; i++) {
            if (lines[i].contains(query)) {
              results.add('$rel:${i + 1}: ${lines[i].trim()}');
              if (results.length >= 50) break;
            }
          }
        } catch (_) {}
      }
      if (results.isEmpty) {
        return AgentToolResult(ok: true, output: '无匹配：$query');
      }
      return AgentToolResult(
          ok: true, output: '搜索 $query 共 ${results.length} 条：\n${results.join('\n')}');
    } catch (e) {
      return AgentToolResult(ok: false, output: '搜索失败：$e');
    }
  }

  // 高危命令黑名单，命中直接拒绝
  static const _dangerousPatterns = [
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
  ];

  // 免询问白名单：只读查询类
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

  static bool isDangerous(String command) {
    final lower = command.toLowerCase();
    return _dangerousPatterns.any(lower.contains);
  }

  static bool isSafeCommand(String command) {
    final trimmed = command.trim();
    return _safePrefixes.any(trimmed.startsWith);
  }

  Future<AgentToolResult> _runCommand(
      Map<String, dynamic> args) async {
    final command = '${args['command'] ?? ''}';
    final timeoutSec = (args['timeout'] as num?)?.toInt() ?? 60;
    if (command.trim().isEmpty) {
      return AgentToolResult(ok: false, output: 'command 不能为空');
    }
    if (isDangerous(command)) {
      return AgentToolResult(
          ok: false, output: '拒绝执行高危命令：$command');
    }
    try {
      final result = await Process.run(
        '/bin/sh',
        ['-c', command],
        workingDirectory: rootPath,
        runInShell: false,
      ).timeout(Duration(seconds: timeoutSec.clamp(5, 300)));
      final out = StringBuffer('\$ $command\n');
      if ('${result.stdout}'.isNotEmpty) out.writeln(result.stdout);
      if ('${result.stderr}'.isNotEmpty) {
        out.writeln('[stderr]');
        out.writeln(result.stderr);
      }
      out.writeln('[exit ${result.exitCode}]');
      return AgentToolResult(
        ok: result.exitCode == 0,
        output: out.toString(),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '命令执行失败：$e');
    }
  }
}
