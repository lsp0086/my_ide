part of 'agent_tools.dart';

/// 有界读域：读文件/锚点读/不匹配提示/最近行/裁剪

Future<List<int>> _readBounded(File file, int cap) async {
  final chunks = <int>[];
  var total = 0;
  await for (final part in file.openRead(0, cap + 1)) {
    chunks.addAll(part);
    total += part.length;
    if (total > cap) break;
  }
  return chunks;
}

extension _AgentToolsFileIoReadExt on AgentTools {

  Future<AgentToolResult> _read(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? ''}';
    final limit = (args['limit'] as num?)?.toInt() ?? 200;
    final offset = (args['offset'] as num?)?.toInt() ?? 0;
    final anchor = (args['anchor'] as num?)?.toInt();
    try {
      // 回收站敏感豁免不可读：WorkspaceFs 对 .my_ide/trash/ 提前 return false 判 inside，
      // 但 trash 条目剥离前缀后可能是已删密钥（.env），直读即泄露。此处纵深补检。
      final trashStripped = _stripTrashPrefix(rel);
      if (trashStripped != null &&
          WorkspaceFs.isSensitiveRelative(trashStripped)) {
        return AgentToolResult(ok: false, output: '敏感路径拒绝读取：$rel');
      }
      // Round4：审批外读同样纵深拒敏感——此前仅 _list 在 allowOutside 时补
      // sensitive 拒绝，读通道可经审批读敏感文件（与写侧不对称）。
      if (allowOutside && WorkspaceFs.isSensitiveRelative(rel)) {
        return AgentToolResult(ok: false, output: '敏感路径拒绝读取：$rel');
      }
      final abs = allowOutside ? _resolveApprovedRead(rel) : _resolve(rel);
      final file = File(abs);
      if (!await file.exists()) {
        return AgentToolResult(ok: false, output: '文件不存在：$rel');
      }
      // 先判大小再读：此前 readAsBytes 全量进内存，GB 级文件直接 OOM。
      // B1：预检失败显式拒绝——此前 length() 抛错被 catch(_) 吞掉后继续
      // readAsBytes 全量读入，IO 异常即静默变全量读（fail-open）。
      // readAsBytes 改 openRead(0, cap+1) 有界读：最多多读 1 字节探测超限。
      const cap = 512 * 1024;
      int fileLen;
      try {
        fileLen = await file.length();
      } catch (e) {
        return AgentToolResult(
          ok: false,
          output: '文件大小探测失败，拒绝读取：$rel（$e）',
        );
      }
      if (fileLen > cap) {
        return AgentToolResult(ok: false, output: '文件过大，拒绝读取：$rel');
      }
      // _readBounded 已由扩展静态成员改为同库顶层函数，直接调用即可。
      final bytes = await _readBounded(file, cap);
      if (bytes.length > cap) {
        return AgentToolResult(ok: false, output: '文件过大，拒绝读取：$rel');
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = text.split('\n');
      // B5 语义锚定：anchor 指定 0-based 行号时按缩进锚定返回包含该行的
      // 整个函数/类块（对齐 Roo Code read_file 语义锚定），比固定窗口切片
      // 少多轮往返；块上限 AgentTools.anchorMaxLines 防超大块灌爆上下文。
      if (anchor != null) {
        return _readAnchored(rel, lines, anchor, limit);
      }
      final start = offset.clamp(0, lines.length);
      final end = (start + limit).clamp(0, lines.length);
      // 单行长度钳制：512KB 内单行超长（压缩/打包/单行 JSON）此前整行
      // 回传灌爆上下文。>2000 字符截断并注明本行总长（对齐命令输出按行
      // 截断口径，只钳展示切片，行数统计不受影响）。
      final slice = lines
          .sublist(start, end)
          .map((l) {
            if (l.length <= 2000) return l;
            return '${l.substring(0, 2000)}…（本行超长已截断：总长 ${l.length} 字符）';
          })
          .join('\n');
      return AgentToolResult(
        ok: true,
        output: '文件 $rel 共 ${lines.length} 行，显示 $start-${end - 1}：\n$slice',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '读取失败：$e');
    }
  }
  /// B5：按 anchor 行缩进锚定函数/类块。目标行可为块内任意行（含空行——
  /// 向下找最近非空行定位所属块）。声明行判定：目标行本身以开括号结尾
  /// 视作声明；闭合一律向上找同缩进非闭合行；普通语句行向上找首个缩进
  /// 更小且以开括号结尾的声明行（跳过闭合同级行），找不到则以目标行为块。
  /// 块终点：从声明行向下，首个"同级闭合行"并入；首个"同级非闭合行"或
  /// "更浅缩进行"前一行为止。超 AgentTools.anchorMaxLines 截断并注明。
  AgentToolResult _readAnchored(
    String rel,
    List<String> lines,
    int anchor,
    int limit,
  ) {
    if (lines.isEmpty) {
      return AgentToolResult(ok: false, output: '文件为空：$rel');
    }
    if (anchor < 0 || anchor >= lines.length) {
      return AgentToolResult(
        ok: false,
        output: 'anchor 越界：$anchor（文件共 ${lines.length} 行）：$rel',
      );
    }
    // 空行归属：向下找最近非空行作为锚定目标；其后全空则向上找。
    var target = anchor;
    while (target < lines.length && lines[target].trim().isEmpty) {
      target++;
    }
    if (target >= lines.length) {
      target = anchor;
      while (target > 0 && lines[target].trim().isEmpty) {
        target--;
      }
    }
    final tIndent = AgentTools._indentWidth(lines[target]);
    final tTrim = lines[target].trim();
    final targetIsCloser =
        tTrim.startsWith('}') || tTrim.startsWith(')') || tTrim.startsWith(']');

    bool opensBlock(String l) {
      final tr = l.trimRight();
      if (tr.isEmpty) return false;
      final last = tr[tr.length - 1];
      return last == '{' || last == '(' || last == '[' || last == ':';
    }

    bool isCloser(String l) {
      final tr = l.trimLeft();
      return tr.startsWith('}') ||
          tr.startsWith(')') ||
          tr.startsWith(']');
    }

    // 定位包含 target 的声明行 decl。
    var decl = target;
    if (targetIsCloser) {
      // 闭合行：向上找首个同缩进非闭合行（闭合与声明间全部为更深缩进）。
      for (var i = target - 1; i >= 0; i--) {
        final l = lines[i];
        if (l.trim().isEmpty) continue;
        if (!isCloser(l) && AgentTools._indentWidth(l) == tIndent) {
          decl = i;
          break;
        }
        if (AgentTools._indentWidth(l) < tIndent) break;
      }
    } else if (!opensBlock(lines[target])) {
      // 普通语句行：向上找首个缩进更小且以开括号/冒号结尾的声明行。
      var found = false;
      for (var i = target - 1; i >= 0; i--) {
        final l = lines[i];
        if (l.trim().isEmpty) continue;
        final ii = AgentTools._indentWidth(l);
        if (ii < tIndent) {
          if (isCloser(l)) continue;
          if (opensBlock(l)) {
            decl = i;
            found = true;
          }
          break;
        }
      }
      if (!found) decl = target;
    }
    final declIndent = AgentTools._indentWidth(lines[decl]);
    // 块终点：向下首个同级闭合行并入；同级非闭合行/更浅行前一行为止。
    var end = lines.length - 1;
    for (var i = decl + 1; i < lines.length; i++) {
      final l = lines[i];
      if (l.trim().isEmpty) continue;
      final ii = AgentTools._indentWidth(l);
      if (ii < declIndent) {
        end = i - 1;
        break;
      }
      if (ii == declIndent) {
        end = isCloser(l) ? i : i - 1;
        break;
      }
      end = i;
    }
    var start = decl;
    var truncatedNote = '';
    if (end - start + 1 > AgentTools.anchorMaxLines) {
      end = start + AgentTools.anchorMaxLines - 1;
      truncatedNote = '…（锚定块超 ${AgentTools.anchorMaxLines} 行已截断）';
    }
    // 单行长度钳制与常规切片同口径。
    final slice = lines
        .sublist(start, end + 1)
        .map((l) {
          if (l.length <= 2000) return l;
          return '${l.substring(0, 2000)}…（本行超长已截断：总长 ${l.length} 字符）';
        })
        .join('\n');
    // limit 作为展示裁剪兜底：块行数超过 limit 时仍返回整块（锚定语义
    // 优先完整块），仅在超大块时由 AgentTools.anchorMaxLines 兜底。
    return AgentToolResult(
      ok: true,
      output:
          '文件 $rel 共 ${lines.length} 行，anchor=$anchor 缩进锚定块 $start-$end'
          '（${end - start + 1} 行，声明行缩进 $declIndent）：\n$slice$truncatedNote',
    );
  }
  /// edit 失败时的可粘贴提示：忽略空白后的首个差异行，帮助模型定位空格/缩进问题。
  /// R4-Ext1 SWE-agent ACI：失败返回行号+修复建议，不静默。
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
          // ACI：给出近似行建议，模型可按建议重读定位。
          final near = _nearestLine(contentLines, want);
          final suggest = near == null
              ? ''
              : '最接近的是第 ${near + 1} 行「${_clip(contentLines[near])}」，请 read_file 确认后原样粘贴。';
          return '首个失配行（去空白后全文件无此行）：「${_clip(oldLines[i])}」。$suggest';
        }
        if (contentLines[hit] != oldLines[i]) {
          return '第 ${hit + 1} 行空白不一致，文件原文为「${_clip(contentLines[hit])}」请原样粘贴。';
        }
      }
    } catch (_) {}
    return '';
  }
  /// ACI 近似行：按词袋交集找最像的一行，无交集返回 null。
  int? _nearestLine(List<String> contentLines, String want) {
    final wantTokens = want
        .split(RegExp(r'\W+'))
        .where((e) => e.isNotEmpty)
        .toSet();
    if (wantTokens.isEmpty) return null;
    var best = -1;
    var bestScore = 0;
    for (var i = 0; i < contentLines.length; i++) {
      final lineTokens = contentLines[i]
          .split(RegExp(r'\W+'))
          .where((e) => e.isNotEmpty)
          .toSet();
      final score = wantTokens.intersection(lineTokens).length;
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return bestScore > 0 ? best : null;
  }
  String _clip(String s, [int max = 80]) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
