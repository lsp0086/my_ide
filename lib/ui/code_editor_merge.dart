part of 'code_editor.dart';









/// 外部内容同步与行级 diff3 三向合并：外部落盘重读（保留撤销栈）、
/// 冲突选"合并"的三方归并（LCS 行对齐 + 变更块提取，纯函数为库内顶层）。
extension CodeEditorMerge on CodeEditorPaneState {
  void _onWorkspaceChanged() {
    _syncExternalContent();
  }

  void _syncExternalContent() {
    final workspace = _workspace;
    if (workspace == null) return;
    final epoch = workspace.contentEpochOf(widget.path);
    if (epoch == _seenContentEpoch) return;
    // F4：加载/保存进行中先不推进 _seenContentEpoch——否则该 epoch 被吞，
    // 本次外部变更永久丢失；加载/保存完成后的下一次 notify 会重新处理。
    if (_loading || _saving) return;
    _seenContentEpoch = epoch;
    // 外部覆盖：干净 tab 才重读磁盘；脏 tab 走冲突抉择，不静默覆盖丢编辑。
    if (_dirty || (workspace.isDirty(widget.path))) {
      workspace.markConflict(widget.path);
      return;
    }
    _mergeExternalDisk();
  }

  /// 干净 tab 的外部合并：以磁盘为准重载，但走 _applyDiskText 保留撤销栈，
  /// Ctrl+Z 可回到合并前，不直接销毁撤销历史。
  Future<void> _mergeExternalDisk() async {
    // D5-S1：外部刷新不得击穿大文件窗口化——窗口态（大文件未展开）
    // 整文件读入物化会让 50MB 文件卡死主 isolate。窗口态跳过自动
    // 磁盘合并，仅记磁盘时间戳防同一变更反复触发；用户点"加载全部"
    // 或重新打开文件后再同步。
    if (_isLargeFile && !_largeFileExpanded) {
      _workspace?.rememberDiskStamp(widget.path);
      return;
    }
    try {
      final disk = await _readText(widget.path);
      if (!mounted) return;
      _applyDiskText(disk);
    } catch (_) {
      if (!mounted) return;
      // 读失败回落 _load（其内部按窗口语义分流，不回退全量读）。
      _load();
    }
  }

  /// 保留撤销栈的磁盘同步：磁盘内容经 controller.text 写入（re_editor 会记一条
  /// 可撤销记录），_savedContent 同步为磁盘态，dirty 清零但撤销历史保留。
  void _applyDiskText(String disk) {
    if (_controller.text == disk) {
      _savedContent = disk;
      if (_dirty) {
        editorSetState(() => _dirty = false);
        _workspace?.setDirty(widget.path, false);
      }
      _workspace?.rememberDiskStamp(widget.path);
      return;
    }
    _savedContent = disk;
    // G-R2-15 agent following：外部落盘（Agent 写路径）后光标跳到首个
    // 变化行——用户能立即看到 Agent 改了哪。仅在干净 tab（外部覆盖语义）
    // 且旧内容非空时生效；脏 tab 走三向合并另有冲突标记定位，不打扰。
    // 用户随后主动点击/输入即自然移走，无需额外禁用标记（每次外部覆盖
    // 只跟随这一次）。
    final prev = _controller.text;
    // 经 setter 写入：re_editor runRevocableOp 会记撤销节点，Ctrl+Z 可回退合并。
    _controller.text = disk;
    if (!mounted) return;
    if (prev.isNotEmpty) {
      final line = firstDiffLineForTest(prev, disk);
      if (line >= 0 && _controller.codeLines.isNotEmpty) {
        // re_editor 光标是 CodeLineSelection（行号+行内偏移），
        // 置到差异行行首即触发滚动跟随。
        final idx = line.clamp(0, _controller.codeLines.length - 1);
        _controller.selection = CodeLineSelection(
          baseIndex: idx,
          baseOffset: 0,
          extentIndex: idx,
          extentOffset: 0,
        );
      }
    }
    editorSetState(() => _dirty = false);
    _workspace?.setDirty(widget.path, false);
    _workspace?.rememberDiskStamp(widget.path);
    _scheduleLocalIntegrityCheck(immediate: true);
  }

  /// 三向合并（冲突选“合并”用）：base=_savedContent，local=当前缓冲，remote=磁盘。
  /// 未改行用磁盘，本地改过行保留本地并插冲突标记；经 controller.text 一次写入，
  /// 撤销栈保留，Ctrl+Z 可回到合并前。
  Future<void> mergeDiskPreservingLocal() async {
    if (_loading || _saving) return;
    // D5-S1：窗口态大文件不做三向合并（合并需 base/local/remote 三方
    // 全文，窗口态物化即击穿窗口化语义）；用户展开后再用。
    if (_isLargeFile && !_largeFileExpanded) return;
    String disk;
    try {
      disk = await _readText(widget.path);
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final local = _controller.text;
    if (local == disk) {
      _applyDiskText(disk);
      return;
    }
    final merged = _threeWayMerge(
      base: _savedContent,
      local: local,
      remote: disk,
    );
    _savedContent = disk;
    _controller.text = merged;
    if (!mounted) return;
    final dirty = merged != disk;
    editorSetState(() {
      _dirty = dirty;
      _gotoHint = dirty ? '已合并外部改动，冲突行已标记，请检查保存' : null;
    });
    _workspace?.setDirty(widget.path, dirty);
    _workspace?.rememberDiskStamp(widget.path);
    _scheduleLocalIntegrityCheck(immediate: true);
  }
}

/// 行级三向合并（S5-4 diff3）：以 base 为锚，分别计算 base→local 与
/// base→remote 的变更块（LCS 行对齐）：两侧不变→base；仅一侧变→采纳该侧；
/// 两侧变区间不重叠→各自采纳；重叠同内容→采纳；重叠异内容→插冲突标记。
/// 行数>2万降级下标对齐。双边都改且不一致时插 <<<<<<< LOCAL / ======= /
/// >>>>>>> DISK 标记，不静默丢任一边。
String _threeWayMerge({
  required String base,
  required String local,
  required String remote,
}) {
  final b = base.split('\n');
  final l = local.split('\n');
  final r = remote.split('\n');
  if (b.length > 20000 || l.length > 20000 || r.length > 20000) {
    return _threeWayMergeByIndex(b: b, l: l, r: r);
  }
  // LCS 行对齐：base 行 -> 对端行（-1 表示删除/无对应）。
  final bl = _lcsAlign(b, l);
  final br = _lcsAlign(b, r);
  // 变更块：base 区间 [start, end) 在对端变为替换行列表。
  final lb = _diffBlocks(b, l, bl);
  final rb = _diffBlocks(b, r, br);
  final out = <String>[];
  var i = 0;
  var li = 0;
  var ri = 0;
  while (i < b.length || li < lb.length || ri < rb.length) {
    final lBlock = li < lb.length ? lb[li] : null;
    final rBlock = ri < rb.length ? rb[ri] : null;
    final lStart = lBlock?.$1 ?? b.length;
    final rStart = rBlock?.$1 ?? b.length;
    final next = lStart < rStart ? lStart : rStart;
    // 锚定行：两侧都没改，直接采纳 base。
    while (i < next && i < b.length) {
      out.add(b[i]);
      i++;
    }
    if (lBlock == null && rBlock == null) break;
    if (lBlock != null && rBlock != null && lStart == rStart) {
      // 同起点变更块：区间与内容都一致→采纳；否则冲突。
      final lEnd = lBlock.$2;
      final rEnd = rBlock.$2;
      final end = lEnd > rEnd ? lEnd : rEnd;
      if (_listEq(lBlock.$3, rBlock.$3)) {
        out.addAll(lBlock.$3);
      } else {
        out.add('<<<<<<< LOCAL');
        out.addAll(lBlock.$3);
        out.add('=======');
        out.addAll(rBlock.$3);
        out.add('>>>>>>> DISK');
      }
      i = end;
      li++;
      ri++;
    } else if (lBlock != null && (rBlock == null || lStart < rStart)) {
      // 仅本地变（或本地块先行且与远端块不重叠）→采纳本地。
      // 若远端块起点落在本地块区间内则视为重叠，走冲突分支。
      if (rBlock != null && rBlock.$1 < lBlock.$2) {
        final end = lBlock.$2 > rBlock.$2 ? lBlock.$2 : rBlock.$2;
        if (_listEq(lBlock.$3, rBlock.$3)) {
          out.addAll(lBlock.$3);
        } else {
          out.add('<<<<<<< LOCAL');
          out.addAll(lBlock.$3);
          out.add('=======');
          out.addAll(rBlock.$3);
          out.add('>>>>>>> DISK');
        }
        i = end;
        li++;
        ri++;
      } else {
        out.addAll(lBlock.$3);
        i = lBlock.$2;
        li++;
      }
    } else if (rBlock != null) {
      // 仅远端变（或远端块先行且与本地块不重叠）→采纳远端。
      if (lBlock != null && lBlock.$1 < rBlock.$2) {
        final end = lBlock.$2 > rBlock.$2 ? lBlock.$2 : rBlock.$2;
        if (_listEq(lBlock.$3, rBlock.$3)) {
          out.addAll(rBlock.$3);
        } else {
          out.add('<<<<<<< LOCAL');
          out.addAll(lBlock.$3);
          out.add('=======');
          out.addAll(rBlock.$3);
          out.add('>>>>>>> DISK');
        }
        i = end;
        li++;
        ri++;
      } else {
        out.addAll(rBlock.$3);
        i = rBlock.$2;
        ri++;
      }
    }
  }
  return out.join('\n');
}

/// 旧下标对齐合并（超长文件降级档）：按行下标逐行比较。
String _threeWayMergeByIndex({
  required List<String> b,
  required List<String> l,
  required List<String> r,
}) {
  final n = [b.length, l.length, r.length].reduce((a, v) => a > v ? a : v);
  final out = <String>[];
  for (var i = 0; i < n; i++) {
    final bb = i < b.length ? b[i] : null;
    final ll = i < l.length ? l[i] : null;
    final rr = i < r.length ? r[i] : null;
    if (ll == rr) {
      if (ll != null) out.add(ll);
      continue;
    }
    if (ll == bb) {
      // 本地未改：用磁盘
      if (rr != null) out.add(rr);
      continue;
    }
    if (rr == bb) {
      // 磁盘未改：保留本地
      if (ll != null) out.add(ll);
      continue;
    }
    // 双边都改且不一致：插冲突标记，两边都保留
    out.add('<<<<<<< LOCAL');
    if (ll != null) out.add(ll);
    out.add('=======');
    if (rr != null) out.add(rr);
    out.add('>>>>>>> DISK');
  }
  return out.join('\n');
}

/// LCS 行对齐：返回 base 每行在对端首次匹配的行号（-1 表示无对应）。
/// 内存 O(n*m) 表过大时（行数乘积>400万）回退贪心匹配防 OOM。
List<int> _lcsAlign(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  final map = List<int>.filled(n, -1);
  if (n == 0 || m == 0) return map;
  if (n * m > 4000000) {
    // 贪心：顺序找首个相等行。
    var j = 0;
    for (var i = 0; i < n && j < m; i++) {
      while (j < m && b[j] != a[i]) {
        j++;
      }
      if (j < m) {
        map[i] = j;
        j++;
      }
    }
    return map;
  }
  // 标准 LCS DP（行内容全等比较），回溯取对齐。
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      if (a[i] == b[j]) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        dp[i][j] = dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1];
      }
    }
  }
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      map[i] = j;
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return map;
}

/// 由对齐结果提取变更块：(baseStart, baseEnd, 替换行)。
/// 未对齐的 base 行视为删除；对端多出的行归入前一块的替换行。
List<(int, int, List<String>)> _diffBlocks(
  List<String> base,
  List<String> other,
  List<int> align,
) {
  final blocks = <(int, int, List<String>)>[];
  var i = 0;
  var j = 0;
  while (i < base.length) {
    if (align[i] == j) {
      // 对齐行：消费，并把对端 j 之前跳过的行视为插入（归入上一块）。
      i++;
      j++;
      continue;
    }
    final ai = align[i];
    if (ai > j) {
      // 对端在 j..<ai 有插入行。
      final inserted = other.sublist(j, ai);
      final prev = blocks.isNotEmpty ? blocks.removeLast() : null;
      if (prev != null && prev.$2 == i) {
        blocks.add((prev.$1, i, [...prev.$3, ...inserted]));
      } else {
        blocks.add((i, i, inserted));
      }
      j = ai + 1;
      i++;
      continue;
    }
    // align[i] == -1：base 行被删除，替换行空。
    final start = i;
    final repl = <String>[];
    while (i < base.length && align[i] == -1) {
      i++;
    }
    // 删除点后若对端有插入行一并归入。
    final aj = i < base.length ? align[i] : -1;
    if (aj > j) {
      repl.addAll(other.sublist(j, aj));
      j = aj + 1;
      i++;
    }
    blocks.add((start, i, repl));
  }
  if (j < other.length) {
    final prev = blocks.isNotEmpty ? blocks.removeLast() : null;
    if (prev != null && prev.$2 == base.length) {
      blocks.add((prev.$1, base.length, [...prev.$3, ...other.sublist(j)]));
    } else {
      blocks.add((base.length, base.length, other.sublist(j)));
    }
  }
  return blocks;
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
