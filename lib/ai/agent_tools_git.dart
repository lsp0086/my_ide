part of 'agent_tools.dart';

/// Git 工具集
extension AgentToolsGit on AgentTools {
  /// B5：有界 git 进程执行——此前 Process.run 无界收 stdout，大仓库
  /// 一次 git diff 可把 Dart 堆吃满（OOM）。改为流式累计 + 字节上限，
  /// 超限 kill 并返回超限提示；stderr 同口径有界；30s 超时兜底。
  static const int _gitMaxStdoutBytes = 2 * 1024 * 1024;

  /// git pathspec 相对化：以根目录 realpath 为锚——工作区经符号链接
  /// 打开时（macOS /tmp → /private/var），_resolve 返回 realpath，
  /// 按 rootPath 词法 relative 会算出 `../..` 仓库外路径被 git 拒绝。
  String _gitPathRel(String rawPath) {
    try {
      final real = _resolve(rawPath);
      final rootReal = WorkspaceFs.realpathOf(p.normalize(rootPath));
      final rel = p.relative(real, from: rootReal);
      if (rel == '.' || !rel.startsWith('..')) return rel;
    } catch (_) {}
    final lexical = p.relative(_lexicalResolve(rawPath), from: rootPath);
    return lexical;
  }

  /// 词法解析（不解析符号链接）：realpath 失败时的兜底。
  String _lexicalResolve(String rawPath) =>
      p.normalize(p.isAbsolute(rawPath) ? rawPath : p.join(rootPath, rawPath));

  Future<(int exitCode, String stdout, String stderr, bool overflow)> _gitRun(
    List<String> args,
  ) async {
    final proc = await Process.start('git', args, workingDirectory: rootPath);
    final outBuf = BytesBuilder(copy: false);
    final errBuf = BytesBuilder(copy: false);
    var outBytes = 0;
    var errBytes = 0;
    var outOverflow = false;
    var errOverflow = false;
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    late StreamSubscription<List<int>> outSub;
    late StreamSubscription<List<int>> errSub;
    outSub = proc.stdout.listen(
      (chunk) {
        if (outBytes >= _gitMaxStdoutBytes) {
          if (!outOverflow) outOverflow = true;
          return;
        }
        outBytes += chunk.length;
        outBuf.add(chunk);
      },
      onDone: outDone.complete,
      onError: (Object _) => outDone.complete(),
      cancelOnError: true,
    );
    errSub = proc.stderr.listen(
      (chunk) {
        if (errBytes >= 64 * 1024) {
          errOverflow = true;
          return;
        }
        errBytes += chunk.length;
        errBuf.add(chunk);
      },
      onDone: errDone.complete,
      onError: (Object _) => errDone.complete(),
      cancelOnError: true,
    );
    var timedOut = false;
    final timer = Timer(const Duration(seconds: 30), () {
      timedOut = true;
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    });
    final code = await proc.exitCode;
    timer.cancel();
    try {
      await outSub.cancel();
    } catch (_) {}
    try {
      await errSub.cancel();
    } catch (_) {}
    await outDone.future;
    await errDone.future;
    var out = utf8.decode(outBuf.takeBytes(), allowMalformed: true);
    var err = utf8.decode(errBuf.takeBytes(), allowMalformed: true);
    if (timedOut) {
      err = 'git 执行超时（30s）已终止\n$err';
    }
    if (outOverflow) {
      out += '\n（B5：输出超过 ${_gitMaxStdoutBytes ~/ (1024 * 1024)}MB 上限已截断，请缩小 path 范围分批查看）';
      err = 'git 输出过大已截断\n$err';
    }
    if (errOverflow) err = '$err\n（stderr 超过 64KB 已截断）';
    return (code, out, err, outOverflow);
  }

  Future<AgentToolResult> _gitStatus(Map<String, dynamic> args) async {
    final rawPath = '${args['path'] ?? '.'}'.trim();
    final includeUntracked = args['includeUntracked'] != false;
    try {
      final path = _resolve(rawPath);
      final (code, out, err, _) = await _gitRun([
        ...AgentTools._safeGitPrefix(),
        'status',
        '--porcelain=v1',
        '--branch',
        if (!includeUntracked) '--untracked-files=no',
        '--',
        _gitPathRel(path),
      ]);
      if (code != 0) {
        return AgentToolResult(ok: false, output: 'git status 失败：$err');
      }
      final files = <Map<String, dynamic>>[];
      String? branch;
      for (final line in out.split('\n')) {
        if (line.startsWith('## ')) {
          branch = line.substring(3).trim();
          continue;
        }
        if (line.length < 3 || line[2] != ' ') continue;
        final code = line.substring(0, 2);
        final file = line.substring(3).trim();
        if (file.isEmpty) continue;
        files.add({
          'path': file,
          'index': code[0],
          'worktree': code[1],
          'staged': code[0] != ' ',
          'unstaged': code[1] != ' ',
          'untracked': code == '??',
        });
      }
      return AgentToolResult(
        ok: true,
        output: jsonEncode({
          'branch': branch,
          'files': files,
          'count': files.length,
        }),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: 'git status 失败：$e');
    }
  }
  Future<AgentToolResult> _gitDiff(Map<String, dynamic> args) async {
    final rawPath = '${args['path'] ?? '.'}'.trim();
    final staged = args['staged'] == true;
    final contextLines = ((args['contextLines'] as num?)?.toInt() ?? 3).clamp(
      0,
      20,
    );
    try {
      final path = _resolve(rawPath);
      final (code, out, err, overflow) = await _gitRun([
        ...AgentTools._safeGitPrefix(),
        'diff',
        '--no-ext-diff',
        '--unified=$contextLines',
        if (staged) '--cached',
        '--',
        _gitPathRel(path),
      ]);
      if (code != 0) {
        return AgentToolResult(ok: false, output: 'git diff 失败：$err');
      }
      // B5：超限即显式失败——截断后的 hunk 集不完整，静默回半份
      // 结构化 diff 会误导 Agent 漏看改动；明确要求缩小范围分批查。
      if (overflow) {
        return AgentToolResult(
          ok: false,
          output: 'git diff 输出超过 2MB 上限已截断（结果不完整），请缩小 path 范围或用 git status 定位后分文件查看',
        );
      }
      final files = <Map<String, dynamic>>[];
      Map<String, dynamic>? current;
      for (final line in out.split('\n')) {
        if (line.startsWith('diff --git ')) {
          final match = RegExp(r'^diff --git a/(.*?) b/(.*)$').firstMatch(line);
          final pathName = match?.group(2) ?? line;
          // 敏感文件只给路径不给行内容：与 read_file 敏感门禁对齐，
          // 否则 search_text/git_diff 可全文带出 .env/密钥内容。
          if (WorkspaceFs.isSensitiveRelative(pathName)) {
            current = {
              'path': pathName,
              'hunks': <Map<String, dynamic>>[],
              'sensitive': true,
            };
            files.add(current);
            continue;
          }
          current = {'path': pathName, 'hunks': <Map<String, dynamic>>[]};
          files.add(current);
        } else if (line.startsWith('@@ ') && current != null) {
          if (current['sensitive'] == true) continue;
          final match = RegExp(
            r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)$',
          ).firstMatch(line);
          (current['hunks'] as List<Map<String, dynamic>>).add({
            'header': line,
            'oldStart': int.tryParse(match?.group(1) ?? '') ?? 0,
            'oldLines': int.tryParse(match?.group(2) ?? '') ?? 1,
            'newStart': int.tryParse(match?.group(3) ?? '') ?? 0,
            'newLines': int.tryParse(match?.group(4) ?? '') ?? 1,
            'section': match?.group(5) ?? '',
            'lines': <String>[],
          });
        } else if (current != null &&
            (line.startsWith('+') ||
                line.startsWith('-') ||
                line.startsWith(' '))) {
          if (current['sensitive'] == true) continue;
          final hunks = current['hunks'] as List<Map<String, dynamic>>;
          if (hunks.isNotEmpty) (hunks.last['lines'] as List<String>).add(line);
        }
      }
      return AgentToolResult(
        ok: true,
        output: jsonEncode({
          'staged': staged,
          'files': files,
          'count': files.length,
        }),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: 'git diff 失败：$e');
    }
  }
  Future<AgentToolResult> _gitPreflight(Map<String, dynamic> args) async {
    final rawPath = '${args['path'] ?? '.'}'.trim();
    final staged = args['staged'] == true;
    try {
      final statusResult = await _gitStatus({
        'path': rawPath,
        'includeUntracked': true,
      });
      if (!statusResult.ok) return statusResult;
      final diffResult = await _gitDiff({
        'path': rawPath,
        'staged': staged,
        'contextLines': 0,
      });
      if (!diffResult.ok) return diffResult;
      final status = jsonDecode(statusResult.output) as Map<String, dynamic>;
      final diff = jsonDecode(diffResult.output) as Map<String, dynamic>;
      final statusFiles = (status['files'] as List?) ?? const [];
      final diffFiles = (diff['files'] as List?) ?? const [];
      final paths = <String>{
        for (final item in statusFiles)
          if (item is Map) '${item['path'] ?? ''}'.trim(),
        for (final item in diffFiles)
          if (item is Map) '${item['path'] ?? ''}'.trim(),
      }..remove('');
      final sensitive = <String>[];
      final risks = <Map<String, dynamic>>[];
      for (final path in paths) {
        if (WorkspaceFs.isSensitiveRelative(path)) {
          sensitive.add(path);
          risks.add({
            'path': path,
            'level': 'high',
            'reason': '路径可能包含密钥、凭据或可执行配置',
          });
          continue;
        }
        final lower = path.toLowerCase();
        final statusItem = statusFiles.whereType<Map>().cast<Map>().firstWhere(
          (item) => '${item['path'] ?? ''}' == path,
          orElse: () => const {},
        );
        if (statusItem['untracked'] == true) {
          risks.add({
            'path': path,
            'level': 'medium',
            'reason': '未跟踪文件，提交前请确认是否应纳入版本控制',
          });
        } else if (lower.endsWith('.lock') || lower.contains('/generated/')) {
          risks.add({
            'path': path,
            'level': 'low',
            'reason': '依赖锁定或生成文件，建议确认变更来源',
          });
        }
      }
      sensitive.sort();
      risks.sort((a, b) => '${a['path']}'.compareTo('${b['path']}'));
      var additions = 0;
      var deletions = 0;
      var hunks = 0;
      for (final item in diffFiles) {
        if (item is! Map) continue;
        final fileHunks = (item['hunks'] as List?) ?? const [];
        hunks += fileHunks.length;
        for (final hunk in fileHunks) {
          if (hunk is! Map) continue;
          for (final line in ((hunk['lines'] as List?) ?? const [])) {
            final text = '$line';
            if (text.startsWith('+') && !text.startsWith('+++')) additions++;
            if (text.startsWith('-') && !text.startsWith('---')) deletions++;
          }
        }
      }
      final changed = diffFiles.length;
      final message = _suggestCommitMessage(diffFiles, additions, deletions);
      // S1-2：git_preflight 只读化——schema 明确"只读不会执行 commit 或 push"，
      // 此前 autoCommit/pushBeforeRisky 开启时在此静默 add -A+commit+push，
      // 违背承诺（未经用户显式提交动作就把工作区内容写进历史）。体检只保留
      // status/diff/敏感文件扫描；actions 恒回 not_executed 占位，提交动作
      // 统一交由版本锚点（GitAnchor.maybeAnchorCommit，pathspec 排除 .my_ide）
      // 或显式审批的 git 命令执行。
      final actions = <String, String>{'commit': 'not_executed', 'push': 'not_executed'};
      return AgentToolResult(
        ok: true,
        output: jsonEncode({
          'branch': status['branch'],
          'staged': staged,
          'summary': {
            'files': changed,
            'additions': additions,
            'deletions': deletions,
            'hunks': hunks,
          },
          'sensitiveFiles': sensitive,
          'risks': risks,
          'commitMessageSuggestion': message,
          'actions': actions,
        }),
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: 'git 提交前检查失败：$e');
    }
  }
  String _suggestCommitMessage(
    List<dynamic> diffFiles,
    int additions,
    int deletions,
  ) {
    if (diffFiles.isEmpty) return 'chore: review working tree changes';
    final paths = diffFiles
        .whereType<Map>()
        .map((item) => '${item['path'] ?? ''}'.toLowerCase())
        .toList();
    final hasTest = paths.any((path) => path.contains('test'));
    final hasDocs = paths.any(
      (path) => path.endsWith('.md') || path.endsWith('.markdown'),
    );
    final hasFix = paths.any(
      (path) => path.contains('fix') || path.contains('bug'),
    );
    final type = hasFix
        ? 'fix'
        : hasTest && !hasDocs
        ? 'test'
        : hasDocs && !hasTest
        ? 'docs'
        : 'chore';
    final plural = diffFiles.length == 1 ? '' : 's';
    return '$type: update ${diffFiles.length} file$plural (+$additions/-$deletions)';
  }
  Future<AgentToolResult> _gitBlame(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) {
      return AgentToolResult(ok: false, output: 'path 不能为空');
    }
    final start = ((args['startLine'] as num?)?.toInt() ?? 1).clamp(1, 1 << 30);
    final count = ((args['lineCount'] as num?)?.toInt() ?? 20).clamp(1, 200);
    try {
      final abs = _resolve(rel);
      final (code, out, err, _) = await _gitRun([
        ...AgentTools._safeGitPrefix(),
        'blame',
        '--line-porcelain',
        '-L',
        '$start,${start + count - 1}',
        '--',
        _gitPathRel(abs),
      ]);
      if (code != 0) {
        return AgentToolResult(ok: false, output: 'git blame 失败：$err');
      }
      return AgentToolResult(ok: true, output: out);
    } catch (e) {
      return AgentToolResult(ok: false, output: 'git blame 失败：$e');
    }
  }
}
