part of 'tool_registry.dart';

/// 只读类工具执行（文件读/git/lsp/诊断/hover）
extension ToolRegistryExecRead on ToolRegistry {

  /// 只读工具组：read/list/search/git/repo_map/semantic/lsp 定位。
  Future<AgentToolResult?> _execReadOnlyTool({
    required String toolName,
    required Map<String, dynamic> effectiveArgs,
    required String rootPath,
    required String sessionId,
    required AgentTools tools,
  }) async {
    // D2-2：无路径参数的聚合只读工具（repo_map/semantic_search）不走路径审批，
    // 敏感过滤由执行层承担（semantic 已跳敏感，repo_map 只输出文件名）。
    // 只读工具抛错也不卡状态：此前 _status(null) 在 await 后，
    // execute 抛错即卡死“正在执行”。execute 本身不抛（返回 Result），
    // 此处加 finally 双保险。配对 token：并发批先完成者只弹自己。
    if (toolName == 'repo_map' || toolName == 'semantic_search') {
      final st = statusBegin('正在执行 $toolName', sessionId: sessionId);
      try {
        final r = await tools.execute(
          toolName,
          effectiveArgs,
          sessionId: sessionId,
        );
        // 仓库内容同样可能含提示注入（注释/文件名/提交信息），恒标不可信
        // 并提级后续写/命令，与 get_diagnostics/lsp_hover 同口径。
        _markUntrusted(
          AgentToolResult(ok: true, output: '', untrusted: true),
          sessionId: sessionId,
        );
        if (!r.ok) return r;
        return AgentToolResult(
          ok: r.ok,
          output: wrapUntrustedToolOutput(
            source: '$toolName:$rootPath',
            body: r.output,
          ),
          touchedFiles: r.touchedFiles,
          preview: r.preview,
          untrusted: true,
          source: '$toolName:$rootPath',
          promptTokens: r.promptTokens,
          completionTokens: r.completionTokens,
        );
      } finally {
        statusEnd(st, sessionId: sessionId);
      }
    }
    final readPath = '${effectiveArgs['path'] ?? '.'}';
    // G6-R2：读类 deny 规则先于分区判定求值，且对符号链接真实落点同样
    // 命中（deny 优先，symlink 不绕过）——命中即拒，不弹窗不读盘。
    if (_readDenyRuleHit(toolName, readPath, rootPath)) {
      return AgentToolResult(
        ok: false,
        output: '读取已被自动审批规则拒绝（deny 优先，含符号链接真实落点）：'
            '$readPath',
      );
    }
    final readZone = tools.fs.zoneOf(readPath);
    if (readZone != FsZone.inside) {
      // D2-3：审批后执行层不支持的工具不再弹窗，直接拒绝，
      // 避免“批了也失败”的误导性审批。
      if (!ToolRegistry._approvedReadSupported(toolName)) {
        return AgentToolResult(
          ok: false,
          output: '区外/敏感路径不支持 $toolName，已拒绝',
        );
      }
      // R-审核接线：区外读取接 approveReadOutside 档位（此前强制 ask）。
      // deny 档一律拒绝（含敏感路径）：此前 readZone==sensitive 分支把
      // deny 降级为 ask 弹窗，与写侧敏感路径永拒口径相反。
      // auto/ask 档下敏感路径仍强制确认：安全底线不走自动。
      final readPolicy = _resolvePolicy(
        approveReadOutside,
        toolName,
        effectiveArgs,
      );
      if (readPolicy == ApprovalAction.deny) {
        return AgentToolResult(ok: false, output: '读取已被审批策略拒绝：$readPath');
      }
      final readNeedsAsk =
          readZone == FsZone.sensitive || readPolicy == ApprovalAction.ask;
      if (readNeedsAsk) {
        final approved = await _gate.askApproval(
          PendingApproval(
            kind: 'file-read',
            title: readZone == FsZone.sensitive ? '读取敏感路径' : '读取工作区外路径',
            // GhostApproval 对齐：审批 detail 首行附 realpath 真实目标，
            // 区内 symlink->区外文件读时用户可见真实落点，不再只见逻辑路径。
            detail:
                '$toolName ${ToolRegistry._realpathForDisplay(readPath, rootPath)}\n${readZone == FsZone.sensitive ? '该路径涉及密钥/可执行配置，' : ''}允许本次读取吗？',
            filePath: readPath,
          ),
          sessionId: sessionId,
          // R1-4：登记 entry id——Runner 单工具超时按 id 精确摘除本条，
          // 不再整会话连坐清空排队审批。
          entryId: ApprovalGate.approvalEntryIdFor(
            sessionId,
            toolName,
            readPath,
          ),
        );
        // A18：与写路径（R5-2）同口径——approved==false 时消费超时标记
        // 区分“超时未决”与“用户拒绝/取消”：超时回可重试的超时占位，
        // 拒绝/取消仍回 null（用户拒绝语义）。
        // S1-12：背压（队列满未送审）回占位说明，不冒充用户拒绝。
        if (!approved || _gate.isSessionCancelled(sessionId)) {
          if (_gate.takeApprovalTimeout(sessionId)) {
            return AgentToolResult(
              ok: false,
              output: '审批超时未决，已跳过：$readPath',
            );
          }
          if (_gate.takeBackpressured(sessionId)) {
            return AgentToolResult(
              ok: false,
              output: '审批队列已满，本次未送审：$readPath\n请先处理在途审批后重试。',
            );
          }
          return null;
        }
      }
      // T2 审批后执行前取消复检：shouldProceed 通过到落盘执行之间
      // 用户点取消仍会继续写盘/跑命令，此处复检直接转中断不执行。
      if (_gate.isSessionCancelled(sessionId)) return null;
      final stAppr = statusBegin('正在执行 $toolName', sessionId: sessionId);
      try {
        final r = await tools.executeApprovedRead(toolName, effectiveArgs);
        _markUntrusted(
          AgentToolResult(ok: true, output: '', untrusted: true),
          sessionId: sessionId,
        );
        if (!r.ok) return r;
        return AgentToolResult(
          ok: r.ok,
          output: wrapUntrustedToolOutput(
            source: '$toolName:$readPath',
            body: r.output,
          ),
          touchedFiles: r.touchedFiles,
          preview: r.preview,
          untrusted: true,
          source: '$toolName:$readPath',
          promptTokens: r.promptTokens,
          completionTokens: r.completionTokens,
        );
      } finally {
        statusEnd(stAppr, sessionId: sessionId);
      }
    }
    final stRead = statusBegin('正在执行 $toolName', sessionId: sessionId);
    try {
      final r = await tools.execute(
        toolName,
        effectiveArgs,
        sessionId: sessionId,
      );
      // 读通道输出恒标不可信：文件正文/搜索命中/git diff/诊断/lsp 均可能含
      // 仓库内预埋注入，此前仅命令/fetch/mcp 提级，读后直写可绕过审批。
      // 围栏为纯标记，不改变 ok/内容，修复流程不受影响。
      _markUntrusted(
        AgentToolResult(ok: true, output: '', untrusted: true),
        sessionId: sessionId,
      );
      if (!r.ok) return r;
      return AgentToolResult(
        ok: r.ok,
        output: wrapUntrustedToolOutput(
          source: '$toolName:$readPath',
          body: r.output,
        ),
        touchedFiles: r.touchedFiles,
        preview: r.preview,
        untrusted: true,
        source: '$toolName:$readPath',
        promptTokens: r.promptTokens,
        completionTokens: r.completionTokens,
      );
    } finally {
      statusEnd(stRead, sessionId: sessionId);
    }
  }

  /// lsp_hover：悬停诊断读取（Runner 注入回调）。
  Future<AgentToolResult?> _execLspHover({
    required Map<String, dynamic> effectiveArgs,
    required String sessionId,
    required AgentMode mode,
  }) async {
    if (mode == AgentMode.chat) {
      return AgentToolResult(
        ok: false,
        output: 'Chat 模式禁止读取编辑器，请切换到 Agent',
      );
    }
    // 已接线：优先调注入的 hoverReader，无则回退可见提示。
    final stHover = statusBegin('正在读取 hover', sessionId: sessionId);
    try {
      final reader = _hoverReader;
      if (reader == null) {
        return AgentToolResult(
          ok: true,
          output: 'lsp_hover 暂未挂载编辑器通道，请改用 read_file 查看。',
        );
      }
      final text = await reader(effectiveArgs);
      _markUntrusted(
        AgentToolResult(ok: true, output: '', untrusted: true),
        sessionId: sessionId,
      );
      return AgentToolResult(
        ok: true,
        output: wrapUntrustedToolOutput(source: 'lsp_hover', body: text),
        untrusted: true,
        source: 'lsp_hover',
      );
    } finally {
      statusEnd(stHover, sessionId: sessionId);
    }
  }

  /// get_diagnostics：内存诊断读取 + 本地兜底。
  Future<AgentToolResult?> _execGetDiagnostics({
    required Map<String, dynamic> effectiveArgs,
    required String sessionId,
    required AgentMode mode,
    required AgentTools tools,
  }) async {
    // 诊断自检：读内存诊断仓库，不走文件审批。
    // 诊断来自外部 linter/仓库内容，属不可信输入：包围栏并提级，
    // 输出仍可用，不影响修复流程。
    if (mode == AgentMode.chat) {
      return AgentToolResult(ok: false, output: 'Chat 模式禁止读取诊断，请切换到 Agent');
    }
    final stDiag = statusBegin('正在读取诊断', sessionId: sessionId);
    try {
      final reader = _readDiagnostics;
      final path = '${effectiveArgs['path'] ?? ''}'.trim();
      if (reader != null) {
        final text = await reader(path.isEmpty ? null : path);
        // B1-2：未挂载（null）不得死路"服务未挂载"——回退本地完整性检查。
        if (text != null) {
          final wrapped = wrapUntrustedToolOutput(
            source: 'diagnostics:${path.isEmpty ? 'all' : path}',
            body: text,
          );
          final result = AgentToolResult(
            ok: true,
            untrusted: true,
            source: 'diagnostics',
            output: wrapped,
          );
          _markUntrusted(result, sessionId: sessionId);
          return result;
        }
      }
      // 回退：直接对磁盘文件跑 AgentTools 本地完整性检查（无头/cron 可用）。
      final local = await tools.execute(
        'get_diagnostics',
        effectiveArgs,
        sessionId: sessionId,
      );
      final wrappedLocal = wrapUntrustedToolOutput(
        source: 'diagnostics-local:${path.isEmpty ? 'all' : path}',
        body: local.output,
      );
      final localResult = AgentToolResult(
        ok: local.ok,
        untrusted: true,
        source: 'diagnostics',
        output: wrappedLocal,
      );
      _markUntrusted(localResult, sessionId: sessionId);
      return localResult;
    } finally {
      statusEnd(stDiag, sessionId: sessionId);
    }
  }

}
