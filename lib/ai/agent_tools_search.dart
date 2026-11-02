part of 'agent_tools.dart';

/// 列表/搜索/repoMap/诊断/语义/LSP
extension AgentToolsSearch on AgentTools {
  Future<AgentToolResult> _list(
    Map<String, dynamic> args, {
    bool allowOutside = false,
  }) async {
    final rel = '${args['path'] ?? '.'}';
    try {
      // D2-4：审批后读敏感目录同样拒绝（与写侧 _resolveAny 同口径），
      // 避免“批了也失败”：调用方已提前拦截，此处为纵深兜底。
      if (allowOutside) {
        final zone = _fs.zoneOf(rel);
        if (zone == FsZone.sensitive) {
          return AgentToolResult(ok: false, output: '敏感路径拒绝读取：$rel');
        }
        // 区外 list 仅允许单文件 stat：目录枚举区外直接拒绝，
        // 避免一次审批枚举任意区外 200 项。
        // B8：单文件承诺落地——此前只拦目录，文件落到底部 Directory.exists
        // 恒 false 报"目录不存在"，审批后仍失败（批了也失败）。文件分支
        // 直接 stat 返回（类型/大小/修改时间），不枚举不读内容。
        final absProbe = _resolveAny(rel);
        // 探测按跟随口径：链接链最终指向目录同样拒绝枚举。
        final probeType = FileSystemEntity.typeSync(absProbe);
        if (probeType == FileSystemEntityType.file) {
          try {
            final st = await File(absProbe).stat();
            return AgentToolResult(
              ok: true,
              output:
                  '文件 $rel：${st.size} 字节，修改于 '
                  '${st.modified.toIso8601String()}。区外路径不支持枚举，'
                  '如需内容请用 read_file 读取该文件。',
            );
          } catch (e) {
            return AgentToolResult(ok: false, output: '读取文件信息失败：$rel（$e）');
          }
        }
        if (probeType == FileSystemEntityType.directory) {
          return AgentToolResult(
            ok: false,
            output: '区外目录不支持枚举，仅允许 read_file 单文件读取：$rel',
          );
        }
      }
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
  /// 会话取消联动：运行中轮询 [isSessionCancelled]，取消即杀底层 isolate 提前返回。
  Future<AgentToolResult> _search(
    Map<String, dynamic> args, {
    bool allowOutside = false,
    String sessionId = '',
  }) async {
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
    final excludeDirs = ((args['excludeDirs'] as List?) ?? const [])
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    try {
      if (allowOutside) {
        // 区外 search 直接拒绝：一次审批即全文扫任意区外目录，
        // 相对区外路径的敏感名单不对称泄露。仅允许 read_file 单文件。
        return AgentToolResult(
          ok: false,
          output: '区外路径不支持全文搜索，仅允许 read_file 单文件读取',
        );
      }
      final searchRoot = _resolve('${args['path'] ?? '.'}');
      // token 恒创建（无会话取消回调时仅凭 cancel() 置位）：30s 熔断/取消
      // 路径经 cancelActiveSearch 杀底层 isolate，不再依赖回调是否接线。
      final cancelToken = SearchCancellationToken.fromPredicate(
        () =>
            sessionWorkCancelled(sessionId) ||
            (isSessionCancelled?.call(sessionId) ?? false),
      );
      _activeSearchTokens.putIfAbsent(sessionId, () => []).add(cancelToken);
      final List<SearchFileGroup> groups;
      try {
        groups = await WorkspaceSearch.search(
          rootPath: searchRoot,
          query: query,
          caseSensitive: caseSensitive,
          wholeWord: wholeWord,
          useRegex: useRegex,
          maxHits: maxResults,
          ignoreDirs: excludeDirs,
          cancellationToken: cancelToken,
        );
      } finally {
        final inflight = _activeSearchTokens[sessionId];
        if (inflight != null) {
          inflight.remove(cancelToken);
          if (inflight.isEmpty) _activeSearchTokens.remove(sessionId);
        }
      }
      final glob = _globToRegExp(include);
      final filtered = glob == null
          ? groups
          : groups.where((g) => glob.hasMatch(g.relativePath)).toList();
      // R1：按相关性重排，最相关的文件先呈现，截断时不丢关键命中。
      final ranked = WorkspaceSearch.rankGroups(filtered, query);
      // 敏感文件只给路径不给行内容：直读 read_file 对敏感路径直接拒绝，
      // 检索此前全文带出行内容造成不对称泄露。
      final sensitivePaths = <String>{};
      for (final g in ranked) {
        if (WorkspaceFs.isSensitiveRelative(g.relativePath)) {
          sensitivePaths.add(g.relativePath);
        }
      }
      final lines = <String>[];
      var total = 0;
      var sensitiveSkipped = 0;
      for (final g in ranked) {
        if (total >= maxResults) break;
        if (glob != null && !glob.hasMatch(g.relativePath)) continue;
        if (sensitivePaths.contains(g.relativePath)) {
          sensitiveSkipped += g.hits.length;
          continue;
        }
        List<String>? fileLines;
        if (contextLines > 0) {
          try {
            // T5 回读钳制到审批目录内：WorkspaceSearch 返回的相对路径不可信，
            // 绝对值/含 .. 时直接跳过该文件上下文，不再拼接读出区外任意文件。
            if (p.isAbsolute(g.relativePath)) continue;
            final abs = p.normalize(p.join(searchRoot, g.relativePath));
            final rootNorm = p.normalize(searchRoot);
            if (abs != rootNorm && !p.isWithin(rootNorm, abs)) continue;
            // realpath 链检查：搜索根含链接/命中链接文件时词法围栏可被穿透，
            // 此前仅 normalize+isWithin，未查 symlink 即读出区外内容进上下文。
            final real = WorkspaceFs.realpathOf(abs);
            final rootReal = WorkspaceFs.realpathOf(rootNorm);
            if (real != rootReal && !p.isWithin(rootReal, real)) continue;
            if (FileSystemEntity.typeSync(abs, followLinks: false) ==
                FileSystemEntityType.link) {
              continue;
            }
            // 先判大小再读：此前 readAsLines 全量进内存，大文件直接 OOM。
            final f = File(abs);
            if (await f.exists() && await f.length() <= 1024 * 1024) {
              fileLines = await f.readAsLines();
            }
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
        if (sensitiveSkipped > 0) {
          return AgentToolResult(
            ok: true,
            output:
                '无匹配：$query（另有 $sensitiveSkipped 条敏感文件命中已隐藏，只显示路径：${sensitivePaths.join(', ')}）',
          );
        }
        return AgentToolResult(ok: true, output: '无匹配：$query');
      }
      final capped = total >= maxResults ? '（已达上限 $maxResults 条）' : '';
      final sensitiveNote = sensitiveSkipped > 0
          ? '（另有 $sensitiveSkipped 条敏感文件命中已隐藏：${sensitivePaths.join(', ')}）'
          : '';
      return AgentToolResult(
        ok: true,
        output:
            '搜索 $query 共 $total 条$capped$sensitiveNote：\n${lines.join('\n')}',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '搜索失败：$e');
    }
  }
  /// C1：仓库地图（目录树 + 符号表摘要），复用 semantic_index.buildRepoMap。
  Future<AgentToolResult> _repoMap() async {
    try {
      final map = await buildRepoMap(rootPath);
      final text = map.toString().trim();
      if (text.isEmpty) return AgentToolResult(ok: true, output: '（空仓库）');
      // A1-9：输出仅文件名+符号名，恒不含秘密，跳过全量脱敏扫描。
      return AgentToolResult(ok: true, output: text, redactOutput: false);
    } catch (e) {
      return AgentToolResult(ok: false, output: '仓库地图失败：$e');
    }
  }
  /// B1-2：本地完整性诊断（无头可跑）——schema 与 plan/写后自检两处提示
  /// 早已引用本工具，此前 switch 无 case，调用即"未知工具"。直接跑
  /// LocalIntegrityChecker（括号/引号/JSON 扫描），不依赖 UI 侧
  /// DiagnosticsStore（ChangeNotifier 绑定 BuildContext，Agent 无上下文）。
  /// LSP 诊断由 IDE 打开文件时产生，Agent 侧以本地检查为自愈闭环入口。
  Future<AgentToolResult> _diagnostics(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    if (rel.isEmpty) {
      return AgentToolResult(ok: false, output: 'get_diagnostics 缺少 path');
    }
    final abs = _resolve(rel);
    final f = File(abs);
    if (!f.existsSync()) {
      return AgentToolResult(ok: false, output: '文件不存在：$rel');
    }
    try {
      // 大文件跳过：本地检查为括号/引号/JSON 全文扫描，>2MB 无收益。
      if (f.lengthSync() > 2 * 1024 * 1024) {
        return AgentToolResult(
          ok: true,
          output: '文件过大（>2MB），已跳过本地完整性检查：$rel',
        );
      }
      final text = await f.readAsString();
      final list = LocalIntegrityChecker.analyze(
        filePath: abs,
        text: text,
        languageId: p.extension(abs).replaceFirst('.', '').toLowerCase(),
      );
      if (list.isEmpty) {
        return AgentToolResult(
          ok: true,
          output: '$rel：本地完整性检查通过（括号/引号/JSON 无问题）',
        );
      }
      final buf = StringBuffer('$rel：本地完整性检查发现 ${list.length} 处问题：\n');
      for (final d in list.take(50)) {
        buf.writeln('- L${d.displayLine}:C${d.displayColumn} '
            '[${d.severity.name}] ${d.message}');
      }
      if (list.length > 50) buf.writeln('（等共 ${list.length} 处）');
      // ok=true：检查本身成功执行，问题在正文呈现；记失败会误触熔断。
      return AgentToolResult(ok: true, output: buf.toString());
    } catch (e) {
      return AgentToolResult(ok: false, output: '诊断检查失败：$e');
    }
  }
  /// C1：语义检索（本地 TF-IDF）：扫 <=256KB 文本文件做词袋排序。
  /// D2-1：跳过敏感路径（与直读门禁对齐，避免“直读禁、检索放”不对称）；
  /// 500 文件上限 + 输出只给路径不给内容。
  Future<AgentToolResult> _semanticSearch(Map<String, dynamic> args) async {
    final query = '${args['query'] ?? ''}'.trim();
    if (query.isEmpty) {
      return AgentToolResult(ok: false, output: 'query 不能为空');
    }
    final maxResults = ((args['maxResults'] as num?)?.toInt() ?? 20).clamp(
      1,
      50,
    );
    try {
      final docs = <SemanticDoc>[];
      // R5-A6 采集截断旗：500 即 break 时尾部未参排，输出附注不再静默。
      var collectTruncated = false;
      // R8-A3 目录流有界：recursive list无take上限，深仓此前流卡死。
      // 现采集计数超2000即停（docs 500+跳过计数同口径）。
      var scanned = 0;
      // B8：32MB 总预算计数。
      var totalBytes = 0;
      await for (final entity in Directory(
        rootPath,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        if (++scanned > 2000) {
          collectTruncated = true;
          break;
        }
        if (docs.length >= 500) {
          collectTruncated = true;
          break;
        }
        final rel = p.relative(entity.path, from: rootPath);
        if (_snapshotSkipped(rel)) continue;
        if (p.basename(rel) == '.DS_Store') continue;
        // 敏感文件不参与检索：直读同样被门禁拒绝。
        if (WorkspaceFs.isSensitiveRelative(rel)) continue;
        try {
          // B8：单文档 64KB + 32MB 总预算——此前 500×256KB≈128MB 文本
          // 全量堆在主 isolate（UI 卡顿+内存尖峰）。超预算置截断旗。
          if (await entity.length() > 64 * 1024) continue;
          if (totalBytes > 32 * 1024 * 1024) {
            collectTruncated = true;
            break;
          }
          final bytes = await entity.readAsBytes();
          totalBytes += bytes.length;
          String? text;
          try {
            text = utf8.decode(bytes, allowMalformed: true);
          } catch (_) {
            continue;
          }
          if (text.trim().isEmpty) continue;
          // 二进制/高控制字符文件跳过，避免乱码进词袋。
          if (AgentTools._looksBinaryText(text)) continue;
          docs.add(SemanticDoc(path: rel, text: text));
        } catch (_) {}
      }
      final ranked = semanticRank(query, docs, maxResults: maxResults);
      if (ranked.isEmpty) {
        return AgentToolResult(ok: true, output: '无语义匹配：$query');
      }
      final lines = ranked
          .map((r) => '${r.path}（${r.score.toStringAsFixed(3)}）')
          .join('\n');
      // R5-A6 截断提示：采集 500 即断（collectTruncated）或 semanticRank
      // 内 500 截断时，尾部不再静默不可见。
      final truncatedNote = collectTruncated ? '\n（仅前500文档参排，尾部未参排）' : '';
      // A1-9：输出仅路径+分数，恒不含秘密，跳过全量脱敏扫描。
      return AgentToolResult(
        ok: true,
        output: '语义检索 $query：\n$lines$truncatedNote',
        redactOutput: false,
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '语义检索失败：$e');
    }
  }
  /// C2：LSP 跳转定义，只读，失败回退友好提示。
  Future<AgentToolResult> _lspDefinition(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    final line = ((args['line'] as num?)?.toInt() ?? 0);
    final character = ((args['character'] as num?)?.toInt() ?? 0);
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      final abs = _resolve(rel);
      final spec = DefinitionService.instance.specForExtension(
        p.extension(abs).toLowerCase(),
      );
      if (spec == null) {
        return AgentToolResult(ok: false, output: '该文件类型无语言服务器：$rel');
      }
      final client = await DefinitionService.instance.clientFor(
        rootPath: rootPath,
        spec: spec,
      );
      if (client == null) {
        final err = DefinitionService.instance.lastStartError ?? '语言服务器不可用';
        return AgentToolResult(ok: false, output: '$err，可改用 search_text');
      }
      final locs = await client.definition(
        filePath: abs,
        line: line,
        character: character,
      );
      if (locs.isEmpty) return AgentToolResult(ok: true, output: '无定义：$rel');
      final lines = locs
          .take(20)
          .map((l) {
            final r = p.isWithin(rootPath, l.filePath)
                ? p.relative(l.filePath, from: rootPath)
                : l.filePath;
            return '$r:${l.line + 1}:${l.character}';
          })
          .join('\n');
      return AgentToolResult(ok: true, output: '定义：\n$lines');
    } catch (e) {
      return AgentToolResult(ok: false, output: '跳转定义失败：$e');
    }
  }
  /// C2：LSP 查引用，只读，失败回退友好提示。
  Future<AgentToolResult> _lspReferences(Map<String, dynamic> args) async {
    final rel = '${args['path'] ?? ''}'.trim();
    final line = ((args['line'] as num?)?.toInt() ?? 0);
    final character = ((args['character'] as num?)?.toInt() ?? 0);
    if (rel.isEmpty) return AgentToolResult(ok: false, output: 'path 不能为空');
    try {
      final abs = _resolve(rel);
      final spec = DefinitionService.instance.specForExtension(
        p.extension(abs).toLowerCase(),
      );
      if (spec == null) {
        return AgentToolResult(ok: false, output: '该文件类型无语言服务器：$rel');
      }
      final client = await DefinitionService.instance.clientFor(
        rootPath: rootPath,
        spec: spec,
      );
      if (client == null) {
        final err = DefinitionService.instance.lastStartError ?? '语言服务器不可用';
        return AgentToolResult(ok: false, output: '$err，可改用 search_text');
      }
      final locs = await client.references(
        filePath: abs,
        line: line,
        character: character,
      );
      if (locs.isEmpty) return AgentToolResult(ok: true, output: '无引用：$rel');
      final lines = locs
          .take(50)
          .map((l) {
            final r = p.isWithin(rootPath, l.filePath)
                ? p.relative(l.filePath, from: rootPath)
                : l.filePath;
            return '$r:${l.line + 1}';
          })
          .join('\n');
      return AgentToolResult(ok: true, output: '引用：\n$lines');
    } catch (e) {
      return AgentToolResult(ok: false, output: '查引用失败：$e');
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
        // 后缀匹配：'.dart' → 匹配以 .dart 结尾（此前单引号内 ${} 未插值，永远不命中）。
        sources.add('.*${RegExp.escape(part)}\$');
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
}
