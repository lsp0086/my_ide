import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../fs/workspace_fs.dart';
import '../workspace/workspace_search.dart';
import 'command_process_manager.dart';
import 'external_content.dart';
import 'url_fetch_policy.dart';

/// Agent 文件工具执行：read/write/edit，限制在工作区内。
class AgentToolResult {
  AgentToolResult({
    required this.ok,
    required this.output,
    this.touchedFiles = const [],
    this.preview,
    this.untrusted = false,
    this.source,
  });

  final bool ok;
  final String output;
  final List<String> touchedFiles;
  final FilePreview? preview;
  /// 网页 / MCP 等外部数据：只能当引用，不能当指令。
  final bool untrusted;
  final String? source;
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

class _PatchOp {
  _PatchOp.edit(this.rel, this.abs, this.oldFragment, this.newFragment)
    : kind = 'edit',
      newContent = null,
      delete = false;

  _PatchOp.create(this.rel, this.abs, this.newContent)
    : kind = 'create',
      oldFragment = null,
      newFragment = null,
      delete = false;

  _PatchOp.delete(this.rel, this.abs)
    : kind = 'delete',
      newContent = null,
      oldFragment = null,
      newFragment = null,
      delete = true;

  final String rel;
  final String abs;
  final String kind;
  /// create 才带整文件；edit 只记替换片段。
  final String? newContent;
  final String? oldFragment;
  final String? newFragment;
  final bool delete;
}

class _PatchPlan {
  _PatchPlan({required this.ok, required this.error, required this.ops});

  _PatchPlan.fail(this.error) : ok = false, ops = const [];

  final bool ok;
  final String error;
  final List<_PatchOp> ops;
}

class _TodoItem {
  _TodoItem({required this.id, required this.content, required this.status});

  final String id;
  final String content;
  final String status;
}

/// 后台长任务：输出环 + 退出码 + 改盘探测，poll_task 轮询/kill。
class _BackgroundTask {
  _BackgroundTask({
    required this.id,
    required this.command,
    required this.process,
    required this.snapshotBefore,
    required this.sessionId,
    required this.workspace,
    required this.startedAt,
    required this.deadline,
  });

  final String id;
  final String command;
  final Process process;
  final Map<String, String> snapshotBefore;
  final String sessionId;
  final String workspace;
  final DateTime startedAt;
  final DateTime deadline;
  final List<String> _lines = [];
  int? exitCode;
  bool finished = false;
  Timer? timeoutTimer;
  int deliveredLines = 0;
  List<String> touchedFiles = const [];

  List<String> get outputLines => List.unmodifiable(_lines);

  void _append(String chunk) {
    for (final line in chunk.split('\n')) {
      final t = line.trimRight();
      if (t.isEmpty) continue;
      _lines.add(t.length > 500 ? '${t.substring(0, 500)}…' : t);
      if (_lines.length > 2000) {
        _lines.removeRange(0, _lines.length - 2000);
      }
    }
  }

  void appendOut(String chunk) => _append(chunk);
  void appendErr(Object e) => _append('$e');
}

class AgentTools {
  AgentTools({required this.rootPath, CommandProcessManager? processManager})
    : _processManager = processManager ?? CommandProcessManager(),
      _fs = WorkspaceFs(rootPath: rootPath);

  final String rootPath;
  final CommandProcessManager _processManager;
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
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'read_file':
        return _read(args);
      case 'write_file':
        return _write(args);
      case 'edit_file':
        return _edit(args);
      case 'apply_patch':
        return _applyPatch(args);
      case 'todo_write':
        return _todoWrite(args);
      case 'fetch_url':
        return _fetchUrl(args);
      case 'delete_file':
        return _delete(args);
      case 'move_file':
        return _move(args);
      case 'list_files':
        return _list(args);
      case 'search_text':
        return _search(args);
      case 'run_command':
        return _runCommand(args);
      case 'poll_task':
        return pollTask(args);
      case 'ask_question':
        // 由 Runner 拦截处理，这里兜底
        return AgentToolResult(ok: false, output: 'ask_question 需经 UI 确认后继续');
      case 'spawn_subagent':
        return AgentToolResult(
          ok: false,
          output: 'spawn_subagent 需经 Runner 调度',
        );
      default:
        return AgentToolResult(ok: false, output: '未知工具：$name');
    }
  }

  /// 审批通过后的区外/敏感只读：仅 read_file / list_files。
  Future<AgentToolResult> executeApprovedRead(
    String name,
    Map<String, dynamic> args,
  ) async {
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

  /// 审批通过后的区外/敏感写入：仅 write_file / edit_file / delete_file / move_file。
  /// 调用方必须先走审批，此处不再二次弹窗，只做落盘。
  Future<AgentToolResult> executeApprovedWrite(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'write_file':
        return _write(args, allowOutside: true);
      case 'edit_file':
        return _edit(args, allowOutside: true);
      case 'apply_patch':
        return _applyPatch(args, allowOutside: true);
      case 'delete_file':
        return _delete(args, allowOutside: true);
      case 'move_file':
        return _move(args, allowOutside: true);
      default:
        return AgentToolResult(
          ok: false,
          output:
              '区外/敏感路径审批后仅支持 write_file / edit_file / delete_file / move_file',
        );
    }
  }

  /// 审批通过后的区外/敏感预览：写/删/移动前展示 Diff 用，同样不落盘。
  Future<AgentToolResult> previewApproved(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'write_file':
        return _writePreview(args, allowOutside: true);
      case 'edit_file':
        return _editPreview(args, allowOutside: true);
      case 'apply_patch':
        return _applyPatchPreview(args, allowOutside: true);
      case 'delete_file':
        return _deletePreview(args, allowOutside: true);
      case 'move_file':
        return _movePreview(args, allowOutside: true);
      default:
        return executeApprovedRead(name, args);
    }
  }

  /// 只做预览不落盘，供审批弹窗展示 Diff。
  Future<AgentToolResult> preview(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'write_file':
        return _writePreview(args);
      case 'edit_file':
        return _editPreview(args);
      case 'apply_patch':
        return _applyPatchPreview(args);
      case 'delete_file':
        return _deletePreview(args);
      case 'move_file':
        return _movePreview(args);
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
        return AgentToolResult(ok: false, output: '文件过大，拒绝读取：$rel');
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = text.split('\n');
      final start = offset.clamp(0, lines.length);
      final end = (start + limit).clamp(0, lines.length);
      final slice = lines.sublist(start, end).join('\n');
      return AgentToolResult(
        ok: true,
        output: '文件 $rel 共 ${lines.length} 行，显示 $start-${end - 1}：\n$slice',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '读取失败：$e');
    }
  }

  Future<AgentToolResult> _write(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final content = '${args['content'] ?? ''}';
    try {
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
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

  Future<AgentToolResult> _edit(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final oldText = '${args['oldText'] ?? ''}';
    final newText = '${args['newText'] ?? ''}';
    try {
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      final content = await file.readAsString();
      if (!content.contains(oldText)) {
        return AgentToolResult(
          ok: false,
          output:
              'oldText 未精确匹配（含空格/换行），请先 read_file 查看原文后原样粘贴。'
              '${_mismatchHint(content, oldText)}',
        );
      }
      final updated = content.replaceFirst(oldText, newText);
      await file.writeAsString(updated);
      return AgentToolResult(
        ok: true,
        output: '已编辑 $rel',
        touchedFiles: [rel],
        preview: FilePreview(
          path: rel,
          oldContent: content,
          newContent: updated,
        ),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '编辑失败：$e');
    }
  }

  /// edit 失败时的可粘贴提示：忽略空白后的首个差异行，帮助模型定位空格/缩进问题。
  String _mismatchHint(String content, String oldText) {
    try {
      final contentLines = content.split('\n');
      final oldLines = oldText.split('\n');
      final norm = contentLines.map((e) => e.trim()).toList();
      for (var i = 0; i < oldLines.length; i++) {
        final want = oldLines[i].trim();
        if (want.isEmpty) continue;
        final hit = norm.indexWhere((e) => e == want);
        if (hit < 0) {
          return '首个失配行（去空白后全文件无此行）：「${_clip(oldLines[i])}」';
        }
        if (contentLines[hit] != oldLines[i]) {
          return '第 ${hit + 1} 行空白不一致，文件原文为「${_clip(contentLines[hit])}」请原样粘贴。';
        }
      }
    } catch (_) {}
    return '';
  }

  String _clip(String s, [int max = 80]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  /// 多文件原子补丁：edit 只记替换片段，不备份旧文件。
  /// 新内容写到 `.myide-new` 后改名覆盖；删除放到最后。失败用反向片段回滚。
  Future<AgentToolResult> _applyPatch(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final planned = _planPatch(args, allowOutside: allowOutside);
    if (!planned.ok) {
      return AgentToolResult(ok: false, output: planned.error);
    }
    final touched = <String>[];
    try {
      await _commitPatchOps(planned.ops);
      touched.addAll(planned.ops.map((e) => e.rel));
      return AgentToolResult(
        ok: true,
        output:
            '已应用补丁 ${planned.ops.length} 个文件：'
            '${planned.ops.map((e) => e.rel).join(', ')}',
        touchedFiles: touched,
      );
    } catch (e) {
      return AgentToolResult(
        ok: false,
        output: '应用补丁失败：$e',
        touchedFiles: touched,
      );
    }
  }

  Future<void> _replaceOver(File tmp, File target) async {
    if (Platform.isWindows && await target.exists()) {
      await target.delete();
    }
    await tmp.rename(target.path);
  }

  Future<void> _commitPatchOps(List<_PatchOp> ops) async {
    final staged = <File>[];
    final committed = <_PatchOp>[];
    try {
      for (final op in ops) {
        if (op.delete) continue;
        final target = File(op.abs);
        await target.parent.create(recursive: true);
        final tmp = File('${target.path}.myide-new');
        if (op.kind == 'create') {
          await tmp.writeAsString(op.newContent!, flush: true);
        } else {
          final current = await target.readAsString();
          final next = current.replaceFirst(op.oldFragment!, op.newFragment!);
          if (next == current) {
            throw StateError('${op.rel} 提交时片段已不匹配');
          }
          await tmp.writeAsString(next, flush: true);
        }
        staged.add(tmp);
      }
      for (final op in ops) {
        if (op.delete) continue;
        final target = File(op.abs);
        await _replaceOver(File('${target.path}.myide-new'), target);
        committed.add(op);
      }
      for (final op in ops) {
        if (!op.delete) continue;
        final target = File(op.abs);
        if (await target.exists()) await target.delete();
        committed.add(op);
      }
    } catch (e) {
      for (final op in committed.reversed) {
        try {
          final target = File(op.abs);
          if (op.kind == 'create' || op.delete) {
            // create 失败回滚 = 删掉新文件；delete 已执行则无法无副本找回，删除放最后把窗口压到最小。
            if (op.kind == 'create' && await target.exists()) {
              await target.delete();
            }
            continue;
          }
          if (!await target.exists()) continue;
          final current = await target.readAsString();
          final prev = current.replaceFirst(op.newFragment!, op.oldFragment!);
          if (prev != current) {
            await target.writeAsString(prev, flush: true);
          }
        } catch (_) {}
      }
      for (final tmp in staged) {
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// apply_patch 预览：只试算不落盘，供审批展示。
  Future<AgentToolResult> _applyPatchPreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final planned = _planPatch(args, allowOutside: allowOutside);
    if (!planned.ok) {
      return AgentToolResult(ok: false, output: planned.error);
    }
    final buf = StringBuffer('补丁预览 ${planned.ops.length} 个文件：\n');
    for (final op in planned.ops) {
      buf.writeln('- ${op.rel}（${op.kind}）');
    }
    return AgentToolResult(
      ok: true,
      output: buf.toString().trimRight(),
      touchedFiles: planned.ops.map((e) => e.rel).toList(),
      preview: FilePreview(
        path: planned.ops.map((e) => e.rel).join(', '),
        oldContent: '',
        newContent: buf.toString(),
      ),
    );
  }

  _PatchPlan _planPatch(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) {
    final raw = args['patches'];
    if (raw is! List || raw.isEmpty) {
      return _PatchPlan.fail('patches 不能为空');
    }
    if (raw.length > 20) {
      return _PatchPlan.fail('单次补丁最多 20 个文件');
    }
    final ops = <_PatchOp>[];
    for (final item in raw) {
      if (item is! Map) return _PatchPlan.fail('patches 项必须是对象');
      final rel = '${item['path'] ?? ''}'.trim();
      if (rel.isEmpty) return _PatchPlan.fail('patch 缺少 path');
      final create = item['create'] == true;
      final delete = item['delete'] == true;
      if (create && delete) {
        return _PatchPlan.fail('$rel 不能同时 create 与 delete');
      }
      late final String abs;
      try {
        abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      } catch (e) {
        return _PatchPlan.fail('$rel 门禁拒绝：$e');
      }
      final file = File(abs);
      final exists = file.existsSync();
      if (delete) {
        if (!exists) return _PatchPlan.fail('$rel 不存在，无法删除');
        ops.add(_PatchOp.delete(rel, abs));
        continue;
      }
      final newText = '${item['newText'] ?? ''}';
      if (create) {
        if (exists) return _PatchPlan.fail('$rel 已存在，create 拒绝覆盖');
        ops.add(_PatchOp.create(rel, abs, newText));
        continue;
      }
      if (!exists) return _PatchPlan.fail('$rel 不存在，请用 create 新建');
      final oldText = '${item['oldText'] ?? ''}';
      if (oldText.isEmpty) {
        return _PatchPlan.fail('$rel edit 缺少 oldText');
      }
      String content;
      try {
        content = file.readAsStringSync();
      } catch (e) {
        return _PatchPlan.fail('$rel 读取失败：$e');
      }
      final hit = _fuzzyMatch(content, oldText, newText);
      if (hit == null) {
        return _PatchPlan.fail(
          '$rel oldText 未匹配（含模糊空白）：${_mismatchHint(content, oldText)}',
        );
      }
      ops.add(_PatchOp.edit(rel, abs, hit.oldFragment, hit.newFragment));
    }
    return _PatchPlan(ok: true, error: '', ops: ops);
  }

  /// 模糊匹配：返回磁盘上的实际旧片段与将写入的新片段，不保留整文件。
  ({String oldFragment, String newFragment})? _fuzzyMatch(
    String content,
    String oldText,
    String newText,
  ) {
    if (content.contains(oldText)) {
      return (oldFragment: oldText, newFragment: newText);
    }
    final contentLines = content.split('\n');
    final oldLines = oldText.split('\n');
    outer:
    for (
      var start = 0;
      start + oldLines.length <= contentLines.length;
      start++
    ) {
      for (var i = 0; i < oldLines.length; i++) {
        if (contentLines[start + i].trim() != oldLines[i].trim()) {
          continue outer;
        }
      }
      final matched = contentLines.sublist(start, start + oldLines.length).join('\n');
      return (oldFragment: matched, newFragment: newText);
    }
    return null;
  }

  /// 待办清单：内存态，全量替换；不传 todos 返回当前清单。
  Future<AgentToolResult> _todoWrite(Map<String, dynamic> args) async {
    final raw = args['todos'];
    if (raw == null) {
      if (_todos.isEmpty) return AgentToolResult(ok: true, output: '待办清单为空');
      return AgentToolResult(ok: true, output: _todosText());
    }
    if (raw is! List) {
      return AgentToolResult(ok: false, output: 'todos 必须是数组');
    }
    if (raw.length > 50) {
      return AgentToolResult(ok: false, output: 'todos 最多 50 项');
    }
    final next = <_TodoItem>[];
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map) {
        return AgentToolResult(ok: false, output: 'todos[$i] 必须是对象');
      }
      final content = '${item['content'] ?? ''}'.trim();
      if (content.isEmpty) {
        return AgentToolResult(ok: false, output: 'todos[$i] 缺少 content');
      }
      next.add(
        _TodoItem(
          id: '${item['id'] ?? 'todo-$i'}',
          content: content.length > 200 ? content.substring(0, 200) : content,
          status: _normalizeTodoStatus('${item['status'] ?? 'pending'}'),
        ),
      );
    }
    _todos
      ..clear()
      ..addAll(next);
    return AgentToolResult(ok: true, output: _todosText());
  }

  String _normalizeTodoStatus(String raw) {
    final s = raw.trim().toLowerCase();
    if (s == 'doing' || s == 'in_progress' || s == 'in-progress') {
      return 'in_progress';
    }
    if (s == 'done' || s == 'completed' || s == 'complete') {
      return 'completed';
    }
    return 'pending';
  }

  String _todosText() {
    final buf = StringBuffer('待办清单（${_todos.length} 项）：\n');
    for (var i = 0; i < _todos.length; i++) {
      final t = _todos[i];
      final mark = t.status == 'completed'
          ? '[x]'
          : t.status == 'in_progress'
          ? '[~]'
          : '[ ]';
      buf.writeln('$mark ${i + 1}. ${t.content}');
    }
    return buf.toString().trimRight();
  }

  /// 待办清单跨 AgentTools 实例共享（Runner 每轮 new 一个，不用 static 会丢）。
  static final List<_TodoItem> _todos = [];

  static UrlFetchPolicy fetchPolicy = UrlFetchPolicy();

  /// 内置网页抓取：http(s) only；DNS 后拒绝私网；每次重定向再验。
  Future<AgentToolResult> _fetchUrl(Map<String, dynamic> args) async {
    final raw = '${args['url'] ?? ''}'.trim();
    if (raw.isEmpty) {
      return AgentToolResult(ok: false, output: 'url 不能为空');
    }
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      return AgentToolResult(ok: false, output: 'url 无效：$raw');
    }
    final blocked = fetchPolicy.rejectLiteral(uri);
    if (blocked != null) {
      return AgentToolResult(ok: false, output: blocked);
    }
    final maxChars = ((args['maxChars'] as num?)?.toInt() ?? 8000).clamp(
      500,
      20000,
    );
    HttpClient? client;
    try {
      final resolved = await fetchPolicy.rejectResolved(uri);
      if (resolved != null) {
        return AgentToolResult(ok: false, output: resolved);
      }
      client = HttpClient();
      client.userAgent = 'my_ide/1.0';
      client.connectionTimeout = const Duration(seconds: 10);
      client.connectionFactory = (url, proxyHost, proxyPort) {
        if (proxyHost != null) {
          throw StateError('拒绝代理抓取');
        }
        return Future(() async {
          final why = await fetchPolicy.rejectResolved(url);
          if (why != null) throw StateError(why);
          final addrs = InternetAddress.tryParse(url.host) != null
              ? [InternetAddress(url.host)]
              : await InternetAddress.lookup(url.host);
          InternetAddress? chosen;
          for (final addr in addrs) {
            if (fetchPolicy.rejectAddress(addr) == null) {
              chosen = addr;
              break;
            }
          }
          if (chosen == null) {
            throw StateError('无允许的解析地址：${url.host}');
          }
          final port = url.hasPort
              ? url.port
              : (url.scheme == 'https' ? 443 : 80);
          return Socket.startConnect(chosen, port);
        });
      };
      var current = uri;
      HttpClientResponse? resp;
      for (var hop = 0; hop <= UrlFetchPolicy.maxRedirects; hop++) {
        final hopBlock = await fetchPolicy.rejectResolved(current);
        if (hopBlock != null) {
          return AgentToolResult(ok: false, output: hopBlock);
        }
        final req = await client.getUrl(current).timeout(
          const Duration(seconds: 10),
        );
        req.followRedirects = false;
        resp = await req.close().timeout(const Duration(seconds: 20));
        if (resp.isRedirect) {
          final loc = resp.headers.value(HttpHeaders.locationHeader);
          resp.listen((_) {}).cancel();
          if (loc == null || loc.isEmpty) {
            return AgentToolResult(ok: false, output: '重定向缺少 Location：$current');
          }
          current = current.resolve(loc);
          continue;
        }
        break;
      }
      if (resp == null) {
        return AgentToolResult(ok: false, output: '抓取失败：$raw');
      }
      if (resp.isRedirect) {
        return AgentToolResult(ok: false, output: '重定向过多：$raw');
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        resp.listen((_) {}).cancel();
        return AgentToolResult(
          ok: false,
          output: '抓取失败 HTTP ${resp.statusCode}：$raw',
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
        builder.add(chunk);
        if (builder.length > 2 * 1024 * 1024) {
          return AgentToolResult(ok: false, output: '页面过大，拒绝抓取：$raw');
        }
      }
      var text = utf8.decode(builder.takeBytes(), allowMalformed: true);
      text = text
          .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
            ' ',
          )
          .replaceAll(
            RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
            ' ',
          )
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.length > maxChars) {
        text = '${text.substring(0, maxChars)}…（已截断）';
      }
      if (text.isEmpty) {
        return AgentToolResult(
          ok: true,
          untrusted: true,
          source: 'fetch_url:$raw',
          output: wrapUntrustedToolOutput(
            source: 'fetch_url:$raw',
            body: '页面无文本内容：$raw',
          ),
        );
      }
      return AgentToolResult(
        ok: true,
        untrusted: true,
        source: 'fetch_url:$raw',
        output: wrapUntrustedToolOutput(
          source: 'fetch_url:$raw',
          body: '抓取 $raw：\n$text',
        ),
      );
    } on TimeoutException {
      return AgentToolResult(ok: false, output: '抓取超时：$raw');
    } catch (e) {
      return AgentToolResult(ok: false, output: '抓取失败：$e');
    } finally {
      client?.close(force: true);
    }
  }

  Future<AgentToolResult> _delete(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    try {
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      await file.delete();
      return AgentToolResult(ok: true, output: '已删除 $rel', touchedFiles: [rel]);
    } catch (e) {
      return AgentToolResult(ok: false, output: '删除失败：$e');
    }
  }

  /// 重命名/移动工作区内文件或目录：同名目标直接拒绝，不覆盖。
  /// [from] 源相对路径，[to] 目标相对路径（可含不同目录，实现 move）。
  Future<AgentToolResult> _move(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final from = '${args['from'] ?? args['path'] ?? ''}';
    final to = '${args['to'] ?? args['newPath'] ?? ''}';
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'move_file 需要 from 与 to');
    }
    try {
      final fromAbs = allowOutside ? _resolveAny(from) : _resolve(from);
      final toAbs = allowOutside ? _resolveAny(to) : _resolve(to);
      final type = FileSystemEntity.typeSync(fromAbs, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '文件不存在：$from');
      }
      if (FileSystemEntity.typeSync(toAbs, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$to');
      }
      await Directory(p.dirname(toAbs)).create(recursive: true);
      if (type == FileSystemEntityType.directory) {
        await Directory(fromAbs).rename(toAbs);
      } else {
        await File(fromAbs).rename(toAbs);
      }
      return AgentToolResult(
        ok: true,
        output: '已移动 $from → $to',
        touchedFiles: [from, to],
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '移动失败：$e');
    }
  }

  Future<AgentToolResult> _movePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final from = '${args['from'] ?? args['path'] ?? ''}';
    final to = '${args['to'] ?? args['newPath'] ?? ''}';
    if (from.isEmpty || to.isEmpty) {
      return AgentToolResult(ok: false, output: 'move_file 需要 from 与 to');
    }
    try {
      final fromAbs = allowOutside ? _resolveAny(from) : _resolve(from);
      final toAbs = allowOutside ? _resolveAny(to) : _resolve(to);
      final type = FileSystemEntity.typeSync(fromAbs, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '文件不存在：$from');
      }
      if (FileSystemEntity.typeSync(toAbs, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return AgentToolResult(ok: false, output: '目标已存在，拒绝覆盖：$to');
      }
      return AgentToolResult(
        ok: true,
        output: '预览移动 $from → $to',
        touchedFiles: [from, to],
        preview: FilePreview(
          path: '$from → $to',
          oldContent: from,
          newContent: to,
        ),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _deletePreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    try {
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
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
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final content = '${args['content'] ?? ''}';
    try {
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      final old = await file.exists() ? await file.readAsString() : '';
      return AgentToolResult(
        ok: true,
        output: '预览 $rel（${content.length} 字符）',
        touchedFiles: [rel],
        preview: FilePreview(path: rel, oldContent: old, newContent: content),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '预览失败：$e');
    }
  }

  Future<AgentToolResult> _editPreview(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final oldText = '${args['oldText'] ?? ''}';
    final newText = '${args['newText'] ?? ''}';
    try {
      final abs = allowOutside ? _resolveAny(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      final content = await file.readAsString();
      if (!content.contains(oldText)) {
        return AgentToolResult(ok: false, output: 'oldText 未精确匹配，请先 read_file');
      }
      final updated = content.replaceFirst(oldText, newText);
      return AgentToolResult(
        ok: true,
        output: '预览编辑 $rel',
        touchedFiles: [rel],
        preview: FilePreview(
          path: rel,
          oldContent: content,
          newContent: updated,
        ),
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

  /// 全文搜索：走 WorkspaceSearch isolate（正则/glob/上下文行/上限），不占 UI isolate。
  Future<AgentToolResult> _search(Map<String, dynamic> args) async {
    final query = '${args['query'] ?? ''}';
    final include = '${args['include'] ?? ''}'.trim();
    if (query.isEmpty) {
      return AgentToolResult(ok: false, output: 'query 不能为空');
    }
    final useRegex = args['regex'] == true;
    final caseSensitive = args['caseSensitive'] == true;
    final wholeWord = args['wholeWord'] == true;
    final contextLines = ((args['contextLines'] as num?)?.toInt() ?? 0).clamp(
      0,
      5,
    );
    final maxResults = ((args['maxResults'] as num?)?.toInt() ?? 50).clamp(
      1,
      200,
    );
    try {
      final groups = await WorkspaceSearch.search(
        rootPath: rootPath,
        query: query,
        caseSensitive: caseSensitive,
        wholeWord: wholeWord,
        useRegex: useRegex,
        maxHits: maxResults,
      );
      final glob = _globToRegExp(include);
      final lines = <String>[];
      var total = 0;
      for (final g in groups) {
        if (total >= maxResults) break;
        if (glob != null && !glob.hasMatch(g.relativePath)) continue;
        List<String>? fileLines;
        if (contextLines > 0) {
          try {
            final abs = p.isAbsolute(g.relativePath)
                ? g.relativePath
                : p.join(rootPath, g.relativePath);
            fileLines = await File(abs).readAsLines();
          } catch (_) {
            fileLines = null;
          }
        }
        for (final h in g.hits) {
          if (total >= maxResults) break;
          total++;
          final text = h.lineText.trim();
          if (contextLines > 0 && fileLines != null) {
            final start = (h.line - contextLines).clamp(0, fileLines.length);
            final end = (h.line + contextLines + 1).clamp(0, fileLines.length);
            final ctx = fileLines
                .sublist(start, end)
                .map((e) => e.trimRight())
                .join(' / ');
            lines.add('${g.relativePath}:${h.line + 1}: $text\n    ↳ $ctx');
          } else {
            lines.add('${g.relativePath}:${h.line + 1}: $text');
          }
        }
      }
      if (lines.isEmpty) {
        return AgentToolResult(ok: true, output: '无匹配：$query');
      }
      final capped = total >= maxResults ? '（已达上限 $maxResults 条）' : '';
      return AgentToolResult(
        ok: true,
        output: '搜索 $query 共 $total 条$capped：\n${lines.join('\n')}',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '搜索失败：$e');
    }
  }

  /// glob/后缀过滤转正则：空→null；含 *?[] 走 glob；否则按后缀匹配。
  RegExp? _globToRegExp(String include) {
    if (include.isEmpty) return null;
    final parts = include
        .split(RegExp(r'[,\s;|]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    final sources = <String>[];
    for (var part in parts) {
      if (part.startsWith('.') &&
          !part.contains('*') &&
          !part.contains('?') &&
          !part.contains('[')) {
        sources.add('.*\\${RegExp.escape(part)}\$');
        continue;
      }
      final buf = StringBuffer();
      for (var i = 0; i < part.length; i++) {
        final c = part[i];
        if (c == '*') {
          buf.write('.*');
        } else if (c == '?') {
          buf.write('.');
        } else if ('\\.^\$+(){}|'.contains(c)) {
          buf.write('\\$c');
        } else if (c == '[' || c == ']') {
          buf.write(c);
        } else {
          buf.write(RegExp.escape(c));
        }
      }
      sources.add('.*$buf\$');
    }
    try {
      return RegExp('(${sources.join('|')})');
    } catch (_) {
      return null;
    }
  }

  /// 命令策略统一委托给 CommandPolicy，此处仅保留兼容转发。
  /// 禁止再维护第二份黑白名单。
  static String get shellExecutable =>
      Platform.isWindows ? 'cmd.exe' : '/bin/sh';

  static List<String> shellArguments(String command) =>
      Platform.isWindows ? ['/c', command] : ['-c', command];

  static String get _shellExecutable => shellExecutable;

  static List<String> _shellArguments(String command) =>
      shellArguments(command);

  static bool isDangerous(String command) => CommandPolicy.isDangerous(command);

  bool isSafeCommand(String command) =>
      CommandPolicy.isSafe(command, rootPath: rootPath);

  Future<AgentToolResult> executeCommand(
    Map<String, dynamic> args, {
    required String sessionId,
    bool allowShell = false,
  }) => _runCommand(args, sessionId: sessionId, allowShell: allowShell);

  Future<AgentToolResult> _runCommand(
    Map<String, dynamic> args, {
    String sessionId = '',
    bool allowShell = false,
  }) async {
    final command = '${args['command'] ?? ''}';
    final timeoutSec = ((args['timeout'] as num?)?.toInt() ?? 60).clamp(5, 300);
    if (command.trim().isEmpty) {
      return AgentToolResult(ok: false, output: 'command 不能为空');
    }
    if (isDangerous(command)) {
      return AgentToolResult(ok: false, output: '拒绝执行高危命令：$command');
    }
    final safe = CommandPolicy.safeInvocation(command, rootPath: rootPath);
    if (safe == null && !allowShell) {
      return AgentToolResult(ok: false, output: '该命令必须经逐次审批后执行：$command');
    }
    // background=true：长任务后台跑，立即返回 taskId，不阻塞 45 步循环。
    if (args['background'] == true) {
      return _startBackgroundCommand(
        command,
        safe: safe,
        timeout: Duration(seconds: timeoutSec),
        sessionId: sessionId,
      );
    }
    // 命令前后快照对比，探测改盘文件（touchedFiles 恒为空会导致 UI 不刷新）。
    final before = await _snapshotWorkspace();
    Process? process;
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    try {
      process = await _processManager.start(
        safe?.executable ?? _shellExecutable,
        safe?.arguments ?? _shellArguments(command),
        workingDirectory: rootPath,
      );
      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .forEach(stdout.write);
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .forEach(stderr.write);
      final exitCode = await process.exitCode.timeout(
        Duration(seconds: timeoutSec),
        onTimeout: () async {
          await _processManager.terminate(process!);
          throw TimeoutException('命令执行超时（${timeoutSec}s）');
        },
      );
      await Future.wait([stdoutDone, stderrDone]);
      final out = StringBuffer('\$ $command\n');
      if (stdout.isNotEmpty) out.writeln(stdout);
      if (stderr.isNotEmpty) {
        out.writeln('[stderr]');
        out.writeln(stderr);
      }
      out.writeln('[exit $exitCode]');
      final touched = await _diffSnapshot(before);
      return AgentToolResult(
        ok: exitCode == 0,
        output: out.toString(),
        touchedFiles: touched,
      );
    } on TimeoutException catch (e) {
      final touched = await _diffSnapshot(before);
      return AgentToolResult(ok: false, output: '$e', touchedFiles: touched);
    } catch (e) {
      if (process != null) await _processManager.terminate(process);
      final touched = await _diffSnapshot(before);
      return AgentToolResult(
        ok: false,
        output: '命令执行失败：$e',
        touchedFiles: touched,
      );
    }
  }

  int _bgSeq = 0;
  final Map<String, _BackgroundTask> _bgTasks = {};

  /// 后台长任务：start 后立即返回 taskId，用 poll_task 轮询/kill。
  Future<AgentToolResult> _startBackgroundCommand(
    String command, {
    SafeCommandInvocation? safe,
    required Duration timeout,
    required String sessionId,
  }) async {
    final id = 'bg-${DateTime.now().millisecondsSinceEpoch}-${_bgSeq++}';
    final startedAt = DateTime.now();
    final before = await _snapshotWorkspace();
    try {
      final proc = await _processManager.start(
        safe?.executable ?? _shellExecutable,
        safe?.arguments ?? _shellArguments(command),
        workingDirectory: rootPath,
      );
      final task = _BackgroundTask(
        id: id,
        command: command,
        process: proc,
        snapshotBefore: before,
        sessionId: sessionId,
        workspace: rootPath,
        startedAt: startedAt,
        deadline: startedAt.add(timeout),
      );
      _bgTasks[id] = task;
      task.timeoutTimer = Timer(timeout, () async {
        if (task.finished) return;
        task.appendErr('命令执行超时（${timeout.inSeconds}s），已终止进程树');
        await _processManager.terminate(proc);
        task.exitCode = await proc.exitCode;
        _finishBackgroundTask(id);
      });
      // 输出流式追加到内存环（上限 2000 行），退出时算 touchedFiles。
      proc.stdout
          .transform(utf8.decoder)
          .listen(task.appendOut, onError: task.appendErr);
      proc.stderr
          .transform(utf8.decoder)
          .listen(task.appendErr, onError: task.appendErr);
      proc.exitCode.then((code) {
        task.exitCode = code;
        _finishBackgroundTask(id);
      });
      return AgentToolResult(
        ok: true,
        output:
            '已后台启动 $id：\$ $command\n'
            '用 poll_task 查输出（taskId=$id），kill=true 可结束。',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '后台启动失败：$e');
    }
  }

  void _finishBackgroundTask(String id) {
    final task = _bgTasks[id];
    if (task == null || task.finished) return;
    task.finished = true;
    task.timeoutTimer?.cancel();
    _diffSnapshot(task.snapshotBefore)
        .then((touched) {
          task.touchedFiles = touched;
        })
        .catchError((_) {});
  }

  /// poll_task：查输出尾部 / kill 结束；kill 后返回改动文件。
  Future<AgentToolResult> pollTask(
    Map<String, dynamic> args, {
    String sessionId = '',
  }) async {
    final id = '${args['taskId'] ?? ''}'.trim();
    if (id.isEmpty) {
      return AgentToolResult(ok: false, output: 'taskId 不能为空');
    }
    final task = _bgTasks[id];
    if (task == null || task.sessionId != sessionId) {
      return AgentToolResult(ok: false, output: '后台任务不存在：$id');
    }
    if (args['kill'] == true) {
      task.timeoutTimer?.cancel();
      await _processManager.terminate(task.process);
      task.finished = true;
      task.exitCode ??= await task.process.exitCode;
      final touched = await _diffSnapshot(task.snapshotBefore);
      task.touchedFiles = touched;
      return AgentToolResult(
        ok: true,
        output:
            '已结束 $id（exit=${task.exitCode ?? '?'}），'
            '改动 ${touched.length} 个文件：${touched.take(10).join(', ')}',
        touchedFiles: touched,
      );
    }
    final tail = ((args['tail'] as num?)?.toInt() ?? 60).clamp(1, 200);
    final lines = task.outputLines;
    final start = task.deliveredLines.clamp(0, lines.length);
    final available = lines.sublist(start);
    final slice = available.length <= tail
        ? available
        : available.sublist(available.length - tail);
    task.deliveredLines = lines.length;
    final status = task.exitCode == null ? '运行中' : '已退出 exit=${task.exitCode}';
    final elapsed = DateTime.now().difference(task.startedAt).inSeconds;
    return AgentToolResult(
      ok: true,
      output:
          '$id $status（${elapsed}s，工作区 ${task.workspace}）：\$ ${task.command}\n'
          '${slice.isEmpty ? '（暂无新增输出）' : slice.join('\n')}',
      touchedFiles: task.touchedFiles,
    );
  }

  Future<void> disposeBackgroundTasks({String? sessionId}) async {
    final tasks = _bgTasks.values
        .where((task) => sessionId == null || task.sessionId == sessionId)
        .toList();
    for (final task in tasks) {
      task.timeoutTimer?.cancel();
      if (!task.finished) {
        await _processManager.terminate(task.process);
        task.finished = true;
        task.exitCode ??= await task.process.exitCode;
        task.touchedFiles = await _diffSnapshot(task.snapshotBefore);
      }
      _bgTasks.remove(task.id);
    }
  }

  static const _snapshotSkipDirs = <String>{
    '.git',
    '.my_ide',
    '.dart_tool',
    '.idea',
    '.vscode',
    'build',
    'dist',
    'node_modules',
    'Pods',
    'DerivedData',
    '__pycache__',
  };

  bool _snapshotSkipped(String rel) {
    if (rel.startsWith('.my_ide') || rel.startsWith('.git/')) return true;
    for (final part in p.split(rel)) {
      if (_snapshotSkipDirs.contains(part)) return true;
    }
    return false;
  }

  /// 工作区快照：path → (size, mtimeMs)，最多 5000 文件，防大目录卡死。
  Future<Map<String, String>> _snapshotWorkspace() async {
    final out = <String, String>{};
    try {
      final root = Directory(rootPath);
      if (!await root.exists()) return out;
      var count = 0;
      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (count >= 5000) break;
        final rel = p.relative(entity.path, from: rootPath);
        if (_snapshotSkipped(rel)) continue;
        try {
          final stat = await entity.stat();
          out[rel] = '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
          count++;
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  Future<List<String>> _diffSnapshot(Map<String, String> before) async {
    final after = await _snapshotWorkspace();
    final touched = <String>[];
    final keys = <String>{...before.keys, ...after.keys};
    for (final key in keys) {
      if (before[key] != after[key]) touched.add(key);
    }
    touched.sort();
    // 上限 200，避免某次全量生成刷爆 UI。
    return touched.length > 200 ? touched.sublist(0, 200) : touched;
  }
}
