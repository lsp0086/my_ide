part of 'tool_registry.dart';

/// MCP resources/prompts 只读执行与路径判定
extension ToolRegistryMcp on ToolRegistry {
  /// R7：MCP resources/prompts 只读执行。输出按 untrusted 包裹，
  /// 与 mcp__ 工具输出同等对待（外部数据不可信）。
  /// R2-10：长MCP读加取消复检+30s超时——此前全程无取消点，
  /// 挂死时取消仍等返回烧token。
  Future<AgentToolResult> _executeMcpRp(
    String toolName,
    Map<String, dynamic> args, {
    String sessionId = '',
  }) async {
    void throwIfCancelled() {
      if (_gate.isSessionCancelled(sessionId)) {
        throw StateError('用户中断，已取消。');
      }
    }

    Future<T> withCancel<T>(Future<T> Function() fn) {
      throwIfCancelled();
      return fn().timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError('$toolName 执行超时（30s）已熔断。'),
      );
    }

    try {
      switch (toolName) {
        case 'mcp_list_resources':
          {
            final all = await withCancel(
              () => McpManager.instance.listAllResources(),
            );
            if (all.isEmpty) {
              return AgentToolResult(ok: true, output: '无可用 MCP resources');
            }
            final buf = StringBuffer();
            all.forEach((serverId, list) {
              buf.writeln('[$serverId]');
              for (final r in list) {
                buf.writeln(
                  '- ${r['uri'] ?? ''}（${r['name'] ?? r['title'] ?? ''}）',
                );
              }
            });
            return _untrustedMcp(
              toolName,
              buf.toString().trim(),
              sessionId: sessionId,
            );
          }
        case 'mcp_list_prompts':
          {
            final all = await withCancel(
              () => McpManager.instance.listAllPrompts(),
            );
            if (all.isEmpty) {
              return AgentToolResult(ok: true, output: '无可用 MCP prompts');
            }
            final buf = StringBuffer();
            all.forEach((serverId, list) {
              buf.writeln('[$serverId]');
              for (final r in list) {
                buf.writeln('- ${r['name'] ?? ''}：${r['description'] ?? ''}');
              }
            });
            return _untrustedMcp(
              toolName,
              buf.toString().trim(),
              sessionId: sessionId,
            );
          }
        case 'mcp_read_resource':
          {
            final serverId = '${args['serverId'] ?? ''}';
            final uri = '${args['uri'] ?? ''}';
            final session = McpManager.instance.sessionOf(serverId);
            if (session == null || !session.connected) {
              return AgentToolResult(ok: false, output: 'MCP 服务器未连接：$serverId');
            }
            final text = await withCancel(() => session.readResource(uri));
            if (text.isEmpty) {
              return AgentToolResult(ok: true, output: '（空 resource）');
            }
            return _untrustedMcp(toolName, text, sessionId: sessionId);
          }
        case 'mcp_get_prompt':
          {
            final serverId = '${args['serverId'] ?? ''}';
            final name = '${args['name'] ?? ''}';
            final session = McpManager.instance.sessionOf(serverId);
            if (session == null || !session.connected) {
              return AgentToolResult(ok: false, output: 'MCP 服务器未连接：$serverId');
            }
            // C4：带参 prompt 透传 arguments（无参传空对象）。
            final promptArgs = args['arguments'];
            final text = await withCancel(
              () => session.getPrompt(
                name,
                promptArgs is Map
                    ? promptArgs.map((k, v) => MapEntry('$k', v))
                    : const {},
              ),
            );
            if (text.isEmpty) {
              return AgentToolResult(ok: true, output: '（空 prompt）');
            }
            return _untrustedMcp(toolName, text, sessionId: sessionId);
          }
      }
      return AgentToolResult(ok: false, output: '未知工具：$toolName');
    } catch (e) {
      return AgentToolResult(ok: false, output: 'MCP 读取失败：$e');
    }
  }

  AgentToolResult _untrustedMcp(
    String toolName,
    String body, {
    String sessionId = '',
  }) {
    final wrapped = wrapUntrustedToolOutput(
      source: 'mcp:$toolName',
      body: body,
    );
    final result = AgentToolResult(
      ok: true,
      untrusted: true,
      source: 'mcp:$toolName',
      output: wrapped,
    );
    // R12R3：按会话归因——此前无 sessionId 只置全局兜底，并行下归因错位。
    _markUntrusted(result, sessionId: sessionId);
    return result;
  }

  /// MCP 参数里疑似路径的值：按工具 inputSchema 的 key 语义识别 +
  /// 通用启发式（盘符/URI/环境变量/穿越），防漏检。
  /// MCP 参数里疑似路径的值：按工具 inputSchema 的 key 语义识别 +
  /// 通用启发式（盘符/URI/环境变量/穿越），防漏检。
  List<String> _mcpPathArgs(Map<String, dynamic> args) {
    final out = <String>[];
    void collect(dynamic v, {String? key}) {
      if (v is String) {
        final s = v.trim();
        if (s.isEmpty) return;
        final k = (key ?? '').toLowerCase();
        // 键名扩充：target/dest/output/src 否则区外直放漏检。
        final looksPathKey =
            k.contains('path') ||
            k.contains('file') ||
            k == 'dir' ||
            k.contains('dir') ||
            k == 'cwd' ||
            k == 'root' ||
            k == 'uri' ||
            k == 'url' ||
            k.contains('folder') ||
            k.contains('directory') ||
            k == 'target' ||
            k == 'dest' ||
            k == 'destination' ||
            k == 'output' ||
            k == 'src' ||
            k == 'source';
        var candidate = s;
        // file:// URI 解包
        if (candidate.toLowerCase().startsWith('file://')) {
          try {
            candidate = Uri.parse(candidate).toFilePath();
          } catch (_) {}
        }
        // 环境变量展开：$HOME / ${HOME} / %USERPROFILE%，读真实环境。
        candidate = candidate.replaceAllMapped(
          RegExp(r'\$([A-Za-z_][A-Za-z0-9_]*)|\$\{([^}]+)\}|%([^%]+)%'),
          (m) {
            final name = m.group(1) ?? m.group(2) ?? m.group(3) ?? '';
            if (name.isEmpty) return '';
            try {
              return Platform.environment[name] ?? '';
            } catch (_) {
              return '';
            }
          },
        );
        final looksPathValue =
            candidate.startsWith('/') ||
            candidate.startsWith('~') ||
            RegExp(r'^[A-Za-z]:[\\/]').hasMatch(candidate) ||
            candidate.startsWith('\\\\') ||
            candidate.contains('..') ||
            candidate.contains('/') ||
            candidate.contains('\\');
        if (looksPathKey || looksPathValue) {
          out.add(candidate.isEmpty ? s : candidate);
        }
        return;
      }
      if (v is Map) {
        v.forEach((k, val) => collect(val, key: '$k'));
      } else if (v is List) {
        for (final e in v) {
          collect(e, key: key);
        }
      }
    }

    collect(args);
    return out;
  }

  String? _mcpFirstPathArg(Map<String, dynamic> args) {
    final paths = _mcpPathArgs(args);
    return paths.isEmpty ? null : paths.first;
  }

  /// MCP 参数命中工作区外/敏感路径则拒绝（副作用受工作区门禁约束）。
  /// 无工作区（rootPath 为空）不再整体短路：仍按敏感路径黑名单校验，
  /// 此前 ~/.ssh 等敏感参数在无工作区时零门禁可直读。黑名单复用
  /// WorkspaceFs.isSensitiveRelative 同一口径：`~` 前缀展开 HOME、
  /// 相对路径按当前目录解析、绝对路径相对 '/' 归一后判敏感段。
  bool _mcpArgsHitDeniedZone(Map<String, dynamic> args, {String? rootPath}) {
    final hasRoot = rootPath != null && rootPath.isNotEmpty;
    final fs = WorkspaceFs(rootPath: rootPath ?? '');
    for (final raw in _mcpPathArgs(args)) {
      final zone = fs.zoneOf(raw);
      if (zone == FsZone.sensitive) return true;
      // 无工作区无"区外"可比：只做敏感黑名单兜底，非敏感路径放行。
      if (!hasRoot) {
        if (_mcpSensitivePathNoWorkspace(raw)) return true;
        continue;
      }
      if (zone != FsZone.inside) return true;
    }
    return false;
  }

  /// 测试钩子：MCP 参数门禁口径（含无工作区敏感黑名单）。
  // ignore: avoid_public_member_api_docs
  /// 测试钩子：MCP 参数门禁口径（含无工作区敏感黑名单）。
  // ignore: avoid_public_member_api_docs
  bool mcpArgsHitDeniedZoneForTest(
    Map<String, dynamic> args, {
    String? rootPath,
  }) => _mcpArgsHitDeniedZone(args, rootPath: rootPath);

  /// 无工作区时的敏感路径黑名单判定（仅门禁用，不改变参数本体）。
  static bool _mcpSensitivePathNoWorkspace(String raw) {
    var candidate = raw;
    if (candidate.startsWith('~')) {
      final home = Platform.environment['HOME'] ?? '';
      // 无法定位 HOME 时保守放行词法路径：仅剩相对路径按 cwd 判定。
      if (home.isEmpty) return false;
      candidate = home + candidate.substring(1);
    }
    if (!p.isAbsolute(candidate)) {
      candidate = p.normalize(p.absolute(candidate));
    }
    final normalized = p.normalize(candidate);
    if (normalized == '/' || normalized == '.') return false;
    return WorkspaceFs.isSensitiveRelative(p.relative(normalized, from: '/'));
  }


  /// MCP 工具执行：审批分级+denied-zone 门禁+untrusted 包裹+artifact 落盘。
  Future<AgentToolResult?> _execMcpTool({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String? rootPath,
    required String sessionId,
  }) async {
    final serverId = McpManager.instance.serverIdOfQualified(toolName);
    final toolShort =
        McpManager.instance.toolNameOfQualified(toolName) ?? toolName;
    if (serverId != null &&
        !McpManager.instance.isToolEnabled(serverId, toolShort)) {
      return AgentToolResult(ok: false, output: 'MCP 工具已在设置里禁用：$toolName');
    }
    if (approveMcp == ApprovalAction.deny) {
      return AgentToolResult(ok: false, output: 'MCP 工具已被策略拒绝：$toolName');
    }
    // 自动审批规则可逐工具放行/拒绝（如只放行 mcp__github__create_issue）：
    // 命中 deny 直接拒绝；命中 auto 且 server 级为 write 时可免全局 ask。
    final mcpRule = _matchAutoApprovalRule(toolName, effectiveArgs);
    if (mcpRule == ApprovalAction.deny) {
      return AgentToolResult(ok: false, output: 'MCP 工具已被自动审批规则拒绝：$toolName');
    }
    final level = serverId == null
        ? McpToolLevel.write
        : McpManager.instance.levelOfServerId(serverId);
    final mcpDenied = _mcpArgsHitDeniedZone(
      effectiveArgs,
      rootPath: rootPath,
    );
    if (mcpDenied) {
      return AgentToolResult(
        ok: false,
        output: 'MCP 参数命中工作区外/敏感路径，已按门禁拒绝：$toolName',
      );
    }
    // shell/网络副作用：auto 策略也升级为 ask，审批标题重点提示风险。
    final mcpRisk = ToolRegistry._mcpArgsHitRisk(effectiveArgs);
    ApprovalAction basePolicy;
    // R2-07：mcpRule ask优先于只读直放——此前ask命中无提级，
    // 配ask的只读MCP仍被静默auto执行。
    if (mcpRule == ApprovalAction.ask) {
      basePolicy = ApprovalAction.ask;
    } else if (level == McpToolLevel.read && !mcpRisk) {
      basePolicy = ApprovalAction.auto;
    } else if (mcpRule == ApprovalAction.auto && !mcpRisk) {
      basePolicy = ApprovalAction.auto;
    } else {
      // network 级此前强制 ask 不接档位；现统一接 approveMcp
      //（用户口径"除删除全部自动审核"，deny 规则与 mcpRisk 升级仍生效）。
      basePolicy = approveMcp;
    }
    // B1-5：first-seen 在最外层提级——新连接 MCP 工具会话首见强制 ask
    // 一次（显式规则命中的工具不打扰，交由用户配置说话）。
    final mcpPolicy = _elevateIfFirstSeen(
      _elevateIfUntrusted(
        (basePolicy == ApprovalAction.auto && mcpRisk)
            ? ApprovalAction.ask
            : basePolicy,
        sessionId: sessionId,
      ),
      toolName,
      explicitRule: mcpRule != null,
      sessionId: sessionId,
    );
    final mcpApproved = await _gate.shouldProceed(
      mcpPolicy,
      PendingApproval(
        kind: 'mcp',
        title: mcpRisk ? '执行 MCP 工具（涉及命令/网络副作用）' : '执行 MCP 工具',
        // C4：annotations 接审批分级——风险工具在标题已提示，此处补 server 级别与只读提示。
        detail:
            '$toolName（server 级别：${level.name}${mcpRisk ? '' : '，只读无副作用'}）\n${_shortJson(effectiveArgs)}'
            '${rootPath == null ? '' : '\n工作区：$rootPath'}',
        filePath: _mcpFirstPathArg(effectiveArgs),
      ),
      sessionId: sessionId,
    );
    if (!mcpApproved || _gate.isSessionCancelled(sessionId)) return null;
    // T2 审批后执行前取消复检：MCP 调用同样不再执行。
    if (_gate.isSessionCancelled(sessionId)) return null;
    final stMcp = statusBegin('正在执行 MCP $toolName', sessionId: sessionId);
    McpCallResult mcp;
    try {
      mcp = await McpManager.instance.callQualifiedTool(
        toolName,
        effectiveArgs,
      );
    } finally {
      statusEnd(stMcp, sessionId: sessionId);
    }
    // B6：MCP 超长输出 Artifact 化（cline §4.1.23 口径）——64k 截断时
    // 全文落盘 .my_ide/artifacts/（复用终端 B6 通道），上下文只留截断
    // 预览+路径，模型可按需 read_file 回读。无工作区/落盘失败跳过。
    var artifactNote = '';
    final full = mcp.fullOutput;
    if (full != null && rootPath != null && rootPath.isNotEmpty) {
      try {
        final dir = Directory(p.join(rootPath, '.my_ide', 'artifacts'));
        await dir.create(recursive: true);
        // B12：artifact 名加 Random.secure 后缀——ms 粒度下并发两同名
        // 工具的 artifact 同名互盖（rename 覆盖），首个结果丢失。
        final name =
            'mcp-$toolName-${DateTime.now().millisecondsSinceEpoch}-'
            '${Random.secure().nextInt(1 << 32).toRadixString(36)}.txt';
        final f = File(p.join(dir.path, name));
        // A20：原子落盘防半写，失败不阻断主流程（原有吞错语义保留）。
        await ToolRegistry._atomicWriteString(f, full);
        artifactNote =
            '\n[artifact] 完整输出已落盘：.my_ide/artifacts/$name'
            '（${full.length} 字符），可用 read_file 按需检索。';
      } catch (_) {}
    }
    final wrapped = wrapUntrustedToolOutput(
      source: 'mcp:$toolName',
      body: '${mcp.output}$artifactNote',
    );
    final result = AgentToolResult(
      ok: mcp.ok,
      untrusted: true,
      source: 'mcp:$toolName',
      output: wrapped,
    );
    _markUntrusted(result, sessionId: sessionId);
    return result;
  }

}
