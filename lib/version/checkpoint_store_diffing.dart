part of 'checkpoint_store.dart';

/// 差量计算、文本重建与行级 diff（changesOf/fileContentAt/lineDiff）
extension CheckpointStoreDiffing on CheckpointStore {
  Future<List<FileChange>> changesOf(String id) async {
    if (!CheckpointStore._isSafeVersionId(id)) return [];
    // D7-5：缓存命中的内部 List 不得外泄（调用方 mutate 会污染差量缓存）。
    if (_diffCache.containsKey(id)) return List.unmodifiable(_diffCache[id]!);
    final versions = _versionsDir;
    if (versions == null) return [];
    final file = File(p.join(versions.path, 'diffs', '$id.json'));
    if (!await file.exists()) return [];
    try {
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final changes = ((data['changes'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => FileChange.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _diffCache[id] = changes;
      _boundVersionCaches();
      return List.unmodifiable(changes);
    } catch (_) {
      return [];
    }
  }
  /// 取某版本某文件的文本：差量链重建；旧 blob / snapshots 仅兼容。
  Future<String?> fileContentAt(String id, String relPath) async {
    final versions = _versionsDir;
    final root = _rootPath;
    // B8+门禁前置：非法 id/越界 rel 不得触发 _loadTree/diff 重建，
    // 否则 crafted 输入先走全链 IO 再被拒，且失败路径不一致。
    if (versions == null ||
        root == null ||
        !_isSafeRestoreRel(root, relPath) ||
        !CheckpointStore._isSafeVersionId(id)) {
      return null;
    }
    final payload = await _filePayload(
      path: relPath,
      hash: (await _loadTree(id))[relPath],
      versionId: id,
    );
    if (payload.binary) return null;
    if (payload.text != null) return payload.text;
    final file = File(p.join(versions.path, 'snapshots', id, relPath));
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }
  Future<_FilePayload> _filePayload({
    required String path,
    required String? hash,
    String? versionId,
    bool fromWorkspace = false,
    String? knownText,
  }) async {
    if (knownText != null) {
      return _FilePayload(text: knownText, binary: false);
    }
    if (hash == null) {
      return const _FilePayload(text: '', binary: false);
    }
    if (fromWorkspace && _rootPath != null) {
      // 投毒 tree 防护：crafted relPath（如 ../../etc/passwd）不得读出区外，
      // 此前直拼 root+path 把区外内容读进 redo/diff 持久化。
      if (!_isSafeRestoreRel(_rootPath!, path)) {
        return const _FilePayload(text: '', binary: false);
      }
      final file = File(p.join(_rootPath!, path));
      if (!await file.exists()) {
        return const _FilePayload(text: '', binary: false);
      }
      try {
        // R7-A1 恢复侧同样2MB门禁：_captureWorkspace快照侧有2MB上限，
        // 恢复侧此前直读，大文件恢复即OOM。现先length预检超限拒读。
        try {
          if (await file.length() > 2 * 1024 * 1024) {
            return const _FilePayload(text: '', binary: false);
          }
        } catch (_) {}
        final bytes = await file.readAsBytes();
        // B14：读后类型复检——读间隙被替换为链接/目录时内容不可信，
        // 非 file 即丢弃该条目（同 catch 分支返回空载荷，不采用读到的一半）。
        if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file) {
          return const _FilePayload(binary: false);
        }
        final text = _decodeText(bytes);
        if (text == null) {
          return _FilePayload(binary: true, bytes: bytes);
        }
        return _FilePayload(text: text, binary: false, bytes: bytes);
      } catch (_) {
        return const _FilePayload(binary: false);
      }
    }
    if (await _blobExists(hash)) {
      final bytes = await _readBlobBytes(hash);
      if (bytes != null) {
        final text = _decodeText(bytes);
        if (text == null) {
          return _FilePayload(binary: true, bytes: bytes);
        }
        return _FilePayload(text: text, binary: false, bytes: bytes);
      }
    }
    final reconstructed = await _textForHash(path, hash, hintId: versionId);
    if (reconstructed != null) {
      return _FilePayload(text: reconstructed, binary: false);
    }
    return const _FilePayload(binary: false);
  }
  Future<String?> _textForHash(
    String path,
    String hash, {
    String? hintId,
  }) async {
    final ordered = _orderedOldToNew();
    var hint = hintId == null
        ? ordered.length - 1
        : ordered.indexWhere((e) => e.id == hintId);
    if (hint < 0) hint = ordered.length - 1;
    for (var i = hint; i >= 0; i--) {
      final tree = await _loadTree(ordered[i].id);
      if (tree[path] != hash) continue;
      return _reconstructText(ordered[i].id, path);
    }
    return null;
  }
  /// 从最旧版本正向套用 unified diff，重建文本。二进制返回 null。
  Future<String?> _reconstructText(String id, String relPath) async {
    final ordered = _orderedOldToNew();
    final end = ordered.indexWhere((e) => e.id == id);
    if (end < 0) return null;
    // R9-A3 重建链回溯上限50：百轮会话此前全链changesOf即IO爆炸。
    // 近50轮未命中即放弃（返回null走missing路径，不产垃圾错文）。
    final start = end - 50 < 0 ? 0 : end - 50;
    String? content;
    var present = false;
    for (var i = start; i <= end; i++) {
      final changes = await changesOf(ordered[i].id);
      FileChange? hit;
      for (final c in changes) {
        if (c.path == relPath) {
          hit = c;
          break;
        }
      }
      if (hit == null) continue;
      if (hit.binary) return null;
      if (hit.type == 'deleted') {
        present = false;
        content = null;
        continue;
      }
      try {
        // R3-V1：重建开校验——此前硬套漂移diff产垃圾错文误导回滚。
        // added不校验（全量新内容无上下文可验，与redo路径同口径），
        // 否则创世added重建即抛错（D3回归）。
        // R3-V1e：校验失败允许形态迁移——relink删中间节点后，
        // 旧差量形状兼容但上下文对不上（如base→user链），硬返null会
        // 把current判空致备份diff坏掉（D3：backup diff丢+行）。
        // 现先校验，StateError则无校验再套一次；形态兼容即自愈，
        // 结构性失败（binary/截断）仍抛错返null。
        try {
          content = _applyUnifiedDiff(
            content ?? '',
            hit.diff,
            validateContext: hit.type != 'added',
          );
        } on StateError {
          content = _applyUnifiedDiff(content ?? '', hit.diff);
        }
        present = true;
      } catch (_) {
        return null;
      }
    }
    return present ? content : null;
  }
  /// [validateContext] 为 true 时校验上下文/删除行与当前内容一致，
  /// 防止把旧基线的差量硬套到已漂移的文件上（Redo 路径必须开启）。
  String _applyUnifiedDiff(
    String oldText,
    String diff, {
    bool validateContext = false,
  }) {
    if (diff.isEmpty) return oldText;
    if (diff.startsWith('@@ binary') || diff.contains('\n@@ binary')) {
      throw StateError('binary diff cannot apply as text');
    }
    final oldLines = oldText.split('\n');
    final out = <String>[];
    var oldIndex = 0;
    final lines = diff.split('\n');
    var i = 0;
    // R3-V1b：跳过 unified diff 文件头 `--- a/…` / `+++ b/…`——
    // 此前头行 `--- a/path` 被误判为删除行（`-` 前缀）、`+++ b/path`
    // 被误判为新增行；不开校验时重建多出垃圾行，开校验即误抛错
    // 致合法链重建返 null（D3 回归：auto-backup 内容读不出）。
    // 只跳过紧随开头的标准头行，内容行 `-`/`+` 不受影响。
    if (i < lines.length && lines[i].startsWith('--- ')) i++;
    if (i < lines.length && lines[i].startsWith('+++ ')) i++;
    while (i < lines.length) {
      final line = lines[i];
      if (line.startsWith('@@ ')) {
        final match = RegExp(
          r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@',
        ).firstMatch(line);
        if (match == null) {
          i++;
          continue;
        }
        final oldStart = int.parse(match.group(1)!);
        final target = oldStart <= 1 ? 0 : oldStart - 1;
        while (oldIndex < target && oldIndex < oldLines.length) {
          out.add(oldLines[oldIndex]);
          oldIndex++;
        }
        i++;
        while (i < lines.length && !lines[i].startsWith('@@ ')) {
          final l = lines[i];
          if (l.startsWith('…')) {
            throw StateError('truncated diff');
          }
          if (l.startsWith('+')) {
            out.add(l.substring(1));
          } else if (l.startsWith('-')) {
            if (validateContext) {
              _expectLine(oldLines, oldIndex, l.substring(1));
            }
            oldIndex++;
          } else if (l.startsWith(' ')) {
            if (validateContext) {
              _expectLine(oldLines, oldIndex, l.substring(1));
            }
            out.add(l.substring(1));
            oldIndex++;
          }
          i++;
        }
        continue;
      }
      i++;
    }
    while (oldIndex < oldLines.length) {
      out.add(oldLines[oldIndex]);
      oldIndex++;
    }
    return out.join('\n');
  }
  void _expectLine(List<String> lines, int index, String expected) {
    // R3-V1c：越界按空行比对——空文本split得['']，生成器对幽灵空行
    // 会产出`-`(删空)+尾部` `(上下文)；合法链尾部上下文越界时
    // expected必为空，此时放行；非空期望越界仍抛错（真漂移）。
    // R3-V1d：空白对空白放行——生成器尾部幽灵` `(上下文) vs
    // 实际串尾`''`，strip后皆空不算漂移（D3回归：backup生成时
    // prev重建被尾部幽灵行杀掉致prev成空，备份diff坏掉）。
    // 真漂移（内容行对不上）仍然抛错。
    final actual = index < lines.length ? lines[index] : '';
    if (actual != expected) {
      if (actual.trim().isEmpty && expected.trim().isEmpty) return;
      throw StateError('差量与工作区内容不匹配：文件在回退后被修改过，请重新检查后再操作');
    }
  }
  List<FileChange> _diffTrees(
    Map<String, String> prev,
    Map<String, String> current,
  ) {
    final changes = <FileChange>[];
    final allKeys = {...prev.keys, ...current.keys}.toList()..sort();
    for (final key in allKeys) {
      final inPrev = prev.containsKey(key);
      final inCurrent = current.containsKey(key);
      if (!inPrev && inCurrent) {
        changes.add(FileChange(path: key, type: 'added', hash: current[key]));
      } else if (inPrev && !inCurrent) {
        changes.add(FileChange(path: key, type: 'deleted', hash: prev[key]));
      } else if (prev[key] != current[key]) {
        changes.add(
          FileChange(path: key, type: 'modified', hash: current[key]),
        );
      }
    }
    return changes;
  }
  Future<void> _persistBinaryPayload(String? hash, _FilePayload payload) async {
    if (hash == null || payload.bytes == null) return;
    if (await _blobExists(hash)) return;
    await _writeBlob(hash, payload.bytes!);
  }
  Future<String> lineDiff(String id, String relPath) async {
    if (!CheckpointStore._isSafeVersionId(id)) return '';
    final changes = await changesOf(id);
    for (final c in changes) {
      if (c.path == relPath &&
          c.diff.isNotEmpty &&
          !c.diff.endsWith('+++ b/$relPath')) {
        // 已有真实 diff（不是旧占位头）
        if (c.diff.contains('\n@@ ') ||
            c.diff.contains('\n+') ||
            c.diff.contains('\n-')) {
          return c.diff;
        }
      }
    }

    final versions = _versionsDir;
    if (versions == null) return '';
    final diffFile = File(p.join(versions.path, 'diffs', '$id.json'));
    String? prevId;
    try {
      final data =
          jsonDecode(await diffFile.readAsString()) as Map<String, dynamic>;
      prevId = data['prevId'] as String?;
    } catch (_) {}
    final newContent = await fileContentAt(id, relPath) ?? '';
    final oldContent = prevId == null
        ? ''
        : await fileContentAt(prevId, relPath) ?? '';
    return _lineDiffText(oldContent, newContent, relPath);
  }
  String _lineDiffText(
    String oldText,
    String newText,
    String path, {
    bool lossy = true,
  }) {
    final a = oldText.split('\n');
    final b = newText.split('\n');
    final buf = StringBuffer('--- a/$path\n+++ b/$path\n');
    const maxLines = 2000;
    final truncated = lossy && (a.length > maxLines || b.length > maxLines);
    final aa = truncated && a.length > maxLines ? a.sublist(0, maxLines) : a;
    final bb = truncated && b.length > maxLines ? b.sublist(0, maxLines) : b;
    if (aa.length * bb.length > 4 * 1000 * 1000) {
      if (!lossy) return _lineDiffGreedy(a, b, path);
      buf.writeln('@@ 文件过大（${a.length}/${b.length} 行，仅对比前 $maxLines 行） @@');
      final n = aa.length < bb.length ? aa.length : bb.length;
      for (var i = 0; i < n; i++) {
        if (aa[i] == bb[i]) continue;
        buf.writeln('-${aa[i]}');
        buf.writeln('+${bb[i]}');
        if (buf.length > 20000) {
          buf.writeln('…（diff 过长已截断，请直接查看文件）');
          break;
        }
      }
      if (truncated) buf.writeln('…（超出 $maxLines 行部分未对比）');
      return buf.toString();
    }
    final lcs = _lcsTable(aa, bb);
    var i = aa.length;
    var j = bb.length;
    final ops = <String>[];
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && aa[i - 1] == bb[j - 1]) {
        ops.add(' ${aa[i - 1]}');
        i--;
        j--;
      } else if (j > 0 && (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j])) {
        ops.add('+${bb[j - 1]}');
        j--;
      } else if (i > 0) {
        ops.add('-${aa[i - 1]}');
        i--;
      } else {
        break;
      }
    }
    final ordered = ops.reversed.toList();
    var oldLine = 1;
    var newLine = 1;
    var idx = 0;
    while (idx < ordered.length) {
      while (idx < ordered.length && ordered[idx].startsWith(' ')) {
        oldLine++;
        newLine++;
        idx++;
      }
      if (idx >= ordered.length) break;
      final hunkStart = idx;
      var oldCount = 0;
      var newCount = 0;
      final hunkOldStart = oldLine;
      final hunkNewStart = newLine;
      final ctxBefore = <String>[];
      var back = hunkStart - 1;
      while (back >= 0 &&
          ordered[back].startsWith(' ') &&
          ctxBefore.length < 3) {
        ctxBefore.insert(0, ordered[back]);
        back--;
      }
      final emit = <String>[...ctxBefore];
      oldCount += ctxBefore.length;
      newCount += ctxBefore.length;
      final adjustedOldStart = hunkOldStart - ctxBefore.length;
      final adjustedNewStart = hunkNewStart - ctxBefore.length;

      while (idx < ordered.length) {
        final op = ordered[idx];
        if (op.startsWith(' ')) {
          var look = idx;
          var spaces = 0;
          while (look < ordered.length &&
              ordered[look].startsWith(' ') &&
              spaces < 7) {
            spaces++;
            look++;
          }
          if (spaces >= 7) {
            for (var k = 0; k < 3 && idx < ordered.length; k++) {
              emit.add(ordered[idx]);
              oldCount++;
              newCount++;
              oldLine++;
              newLine++;
              idx++;
            }
            break;
          }
          emit.add(op);
          oldCount++;
          newCount++;
          oldLine++;
          newLine++;
          idx++;
        } else if (op.startsWith('+')) {
          emit.add(op);
          newCount++;
          newLine++;
          idx++;
        } else if (op.startsWith('-')) {
          emit.add(op);
          oldCount++;
          oldLine++;
          idx++;
        } else {
          idx++;
        }
      }
      buf.writeln(
        '@@ -$adjustedOldStart,$oldCount +$adjustedNewStart,$newCount @@',
      );
      for (final line in emit) {
        buf.writeln(line);
      }
    }
    if (ordered.isEmpty) {
      buf.writeln('@@ -1,0 +1,0 @@');
    }
    return buf.toString();
  }
  List<List<int>> _lcsTable(List<String> a, List<String> b) {
    // 第1轮R3-1：超限抛错不再分配。
    if (a.length * b.length > 4 * 1000 * 1000) {
      throw StateError('diff过大已转贪心路径');
    }
    final dp =
        List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
    for (var x = 1; x <= a.length; x++) {
      for (var y = 1; y <= b.length; y++) {
        dp[x][y] = a[x - 1] == b[y - 1]
            ? dp[x - 1][y - 1] + 1
            : (dp[x - 1][y] > dp[x][y - 1] ? dp[x - 1][y] : dp[x][y - 1]);
      }
    }
    return dp;
  }
  /// 第1轮R3-1测试钩子：超限抛错口径（不分配矩阵）。
  List<List<int>> debugLcsTableForTest(List<String> a, List<String> b) =>
      _lcsTable(a, b);
  /// 大文件无损差量：线性扫一遍找同步点，不截断、不建 LCS 矩阵。
  String _lineDiffGreedy(List<String> a, List<String> b, String path) {
    final buf = StringBuffer('--- a/$path\n+++ b/$path\n');
    var i = 0;
    var j = 0;
    var emitted = false;
    while (i < a.length || j < b.length) {
      if (i < a.length && j < b.length && a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      final oldStart = i + 1;
      final newStart = j + 1;
      final dels = <String>[];
      final adds = <String>[];
      var found = false;
      for (var ni = i; ni < a.length && !found; ni++) {
        final limit = j + 256 < b.length ? j + 256 : b.length;
        for (var nj = j; nj < limit; nj++) {
          if (a[ni] == b[nj]) {
            dels.addAll(a.sublist(i, ni));
            adds.addAll(b.sublist(j, nj));
            i = ni;
            j = nj;
            found = true;
            break;
          }
        }
      }
      if (!found) {
        dels.addAll(a.sublist(i));
        adds.addAll(b.sublist(j));
        i = a.length;
        j = b.length;
      }
      buf.writeln('@@ -$oldStart,${dels.length} +$newStart,${adds.length} @@');
      for (final line in dels) {
        buf.writeln('-$line');
      }
      for (final line in adds) {
        buf.writeln('+$line');
      }
      emitted = true;
    }
    if (!emitted) buf.writeln('@@ -1,0 +1,0 @@');
    return buf.toString();
  }

  Future<List<FileChange>> _materializeDiffs({
    required List<FileChange> changes,
    required Map<String, String> prevFiles,
    required Map<String, String> currentFiles,
    String? prevId,
    String? currentId,
    bool currentFromWorkspace = false,
    Map<String, String>? currentTexts,
  }) async {
    final out = <FileChange>[];
    for (final c in changes) {
      final prev = await _filePayload(
        path: c.path,
        hash: prevFiles[c.path],
        versionId: prevId,
      );
      final current = await _filePayload(
        path: c.path,
        hash: currentFiles[c.path],
        fromWorkspace: currentFromWorkspace,
        versionId: currentFromWorkspace ? null : currentId,
        knownText: currentTexts?[c.path],
      );
      final binary = prev.binary || current.binary;
      if (binary) {
        await _persistBinaryPayload(prevFiles[c.path], prev);
        await _persistBinaryPayload(currentFiles[c.path], current);
        out.add(
          FileChange(
            path: c.path,
            type: c.type,
            hash: c.hash,
            binary: true,
            diff: '@@ binary ${c.type} ${c.path} @@',
          ),
        );
        continue;
      }
      // A11：重建失败的 text null 不得用 '' 兜底生成"从空串改为现内容"的
      // 错误 diff 落盘（_reconstructText 注释承诺"null 走 missing 路径不产
      // 垃圾"）——缺数据即抛错中止重链，不重写该 diff；调用方（恢复/提交）
      // 已有 fail-closed 中止通道。
      if (prev.text == null || current.text == null) {
        throw StateError(
          '版本数据缺失：${c.path} 文本不可重建（prevId=$prevId currentId=$currentId），'
          '已中止生成 diff，不落盘错误链',
        );
      }
      out.add(
        FileChange(
          path: c.path,
          type: c.type,
          hash: c.hash,
          diff: _lineDiffText(prev.text!, current.text!, c.path, lossy: false),
        ),
      );
    }
    return out;
  }
}
