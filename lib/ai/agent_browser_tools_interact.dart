part of 'agent_browser_tools.dart';

/// 交互注入
extension AgentBrowserToolsInteract on AgentBrowserTools {
  Future<AgentToolResult> _click(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    // B2-1：ref 与 selector 二选一——ref 为快照 eN，经 ref 表解析（DOM 变更
    // 即 stale 明确报错），优先 selector 向后兼容。
    final ref = '${args['ref'] ?? ''}'.trim();
    if (selector.isEmpty && ref.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_click 缺少 selector 或 ref');
    }
    final force = args['force'] == true;
    // C4：fileChooserFiles 可选回填——点击触发原生文件选择器时（自定义
    // 上传按钮），开启拦截并经 DOM.setFileInputFiles 回填工作区内文件。
    final rawChooser = args['fileChooserFiles'];
    final chooserFiles = <String>[
      if (rawChooser is List)
        for (final f in rawChooser)
          if ('$f'.trim().isNotEmpty) '$f'.trim(),
    ];
    if (chooserFiles.length > 10) {
      return AgentToolResult(
        ok: false,
        output: 'fileChooserFiles 最多 10 个文件',
      );
    }
    try {
      final out = await service.click(
      selector,
      force: force,
      fileChooserFiles: chooserFiles,
      ref: ref.isEmpty ? null : ref,
    );
    // B2-6：可选动作后快照——一次点击返回即可判断新状态（弹对话框/
    // 跳转/新元素出现），无需额外 read 调用；默认关保持输出体积。
    var result = out;
    if (args['autoSnapshot'] == true) {
      final snap = await service.snapshot(maxNodes: 40);
      result = '$out\n—— 动作后快照 ——\n$snap';
    }
    return _untrusted(
      'browser_click:${service.currentUrl}',
      '点击 ${selector.isEmpty ? 'ref $ref' : selector}：\n$result',
    );
    } catch (e) {
      return AgentToolResult(ok: false, output: '点击失败：$e');
    }
  }

  /// 输入：有副作用，走 browser_eval 同通道审批（Registry 侧）。

  Future<AgentToolResult> _fill(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    // B2-1：ref 与 selector 二选一（见 _click 同口径）。
    final ref = '${args['ref'] ?? ''}'.trim();
    final text = '${args['text'] ?? ''}';
    if (selector.isEmpty && ref.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_fill 缺少 selector 或 ref');
    }
    // B13：slowly 逐字符输入——insertText 不触发只监听 key* 事件的输入框
    // （验证码/掩码/自绘组件）的 per-char onChange。默认 false 保持
    // insertText 整段快口径。
    final slowly = args['slowly'] == true;
    // B2-8：sensitive 占位符表（browser-use sensitive_data 口径）——text 中
    // 的 {{name}} 在 service 键入时替换为真实值，真实值不回显到工具输出、
    // 审计日志与对话历史（模型只见占位符）。键 ≤64 字符、单值 ≤200 字符、
    // 最多 8 个。
    final sensitive = <String, String>{};
    final rawSensitive = args['sensitive'];
    if (rawSensitive is Map) {
      for (final e in rawSensitive.entries) {
        final k = '${e.key}'.trim();
        final v = '${e.value}';
        if (k.isEmpty || k.length > 64 || v.length > 200) {
          return AgentToolResult(
            ok: false,
            output: 'browser_fill sensitive 参数非法（键 ≤64、值 ≤200 字符）',
          );
        }
        sensitive[k] = v;
      }
      if (sensitive.length > 8) {
        return AgentToolResult(
          ok: false,
          output: 'browser_fill sensitive 最多 8 个占位符',
        );
      }
    }
    try {
      var out = slowly
          ? await service.fillSlowly(
              selector,
              text,
              ref: ref.isEmpty ? null : ref,
              sensitive: sensitive,
            )
          : await service.fill(
              selector,
              text,
              ref: ref.isEmpty ? null : ref,
              sensitive: sensitive,
            );
      // B2-6：可选动作后快照（同 browser_click 口径）。
      if (args['autoSnapshot'] == true) {
        final snap = await service.snapshot(maxNodes: 40);
        out = '$out\n—— 动作后快照 ——\n$snap';
      }
      // B2-8：输出兜底脱敏——错误/快照路径任何真实值出现即替换回占位符。
      final body = redactSensitiveForTest(
        '输入 ${selector.isEmpty ? 'ref $ref' : selector}：\n$out',
        sensitive,
      );
      return _untrusted(
        'browser_fill:${service.currentUrl}',
        body,
      );
    } catch (e) {
      return AgentToolResult(
        ok: false,
        output: redactSensitiveForTest('输入失败：$e', sensitive),
      );
    }
  }

  Future<AgentToolResult> _eval(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    // R2-07：blocked页只读隔离（同_read口径）——eval 同样可外传私页内容。
    if (service.urlBlocked) {
      return AgentToolResult(
        ok: false,
        output: '当前页面被门禁拦截（blocked：${service.currentUrl}），只读通道已隔离，请切回可信页后再执行',
      );
    }
    final js = '${args['js'] ?? ''}';
    if (js.trim().isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_eval 缺少 js');
    }
    // R3-M9：userGesture 可选项（剪贴板等需手势 API 用）。
    // 清单高1：contextId 指定帧执行上下文（iframe 内 eval 用）。
    final userGesture = args['userGesture'] == true;
    // GB8：read_only 只读模式（默认 false）——Runtime.evaluate
    // throwOnSideEffect:true，副作用表达式被 V8 拒绝（EvalError），纯读取
    // 返回。blocked/untrusted 页无风险探查用。
    final readOnly = args['read_only'] == true;
    int? contextId;
    final rawCtx = args['contextId'];
    if (rawCtx is num) {
      contextId = rawCtx.toInt();
    } else if (rawCtx is String) {
      contextId = int.tryParse(rawCtx.trim());
    }
    try {
      final out = await service.evaluate(
        js,
        userGesture: userGesture,
        contextId: contextId,
        readOnly: readOnly,
      );
      return _untrusted(
        'browser_eval:${service.currentUrl}',
        '执行结果${readOnly ? '（read_only）' : ''}：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '执行失败：$e');
    }
  }

  /// G2-4 共享：20K 字符预算截断（R3-BR3/R2-BR8 口径单源化）——首尾保留
  /// 可定位、中间省略 N 条，单行超 1000 单独截断。lines 为待输出行。

  Future<AgentToolResult> _drag(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final from = '${args['from'] ?? args['src'] ?? ''}'.trim();
    final to = '${args['to'] ?? args['dst'] ?? ''}'.trim();
    // B2-1：双端 ref 与 selector 二选一（见 _click 同口径）。
    final fromRef = '${args['fromRef'] ?? args['srcRef'] ?? ''}'.trim();
    final toRef = '${args['toRef'] ?? args['dstRef'] ?? ''}'.trim();
    if ((from.isEmpty && fromRef.isEmpty) || (to.isEmpty && toRef.isEmpty)) {
      return AgentToolResult(ok: false, output: 'browser_drag 缺少 from/to');
    }
    // B11：HTML5 dataTransfer 数据项（可选）——{"text/plain":"hello"}。
    // 页面 dragover/drop 读 dataTransfer 才放行的场景必须带，否则合成拖拽
    // 被业务侧拒收。非 Map 或空表视为未提供。
    Map<String, dynamic>? dt;
    final rawDt = args['dataTransfer'];
    if (rawDt is Map && rawDt.isNotEmpty) {
      dt = Map<String, dynamic>.from(rawDt);
    }
    try {
      final out = await service.drag(
        from,
        to,
        dataTransfer: dt,
        srcRef: fromRef.isEmpty ? null : fromRef,
        dstRef: toRef.isEmpty ? null : toRef,
      );
      return _untrusted(
        'browser_drag:${service.currentUrl}',
        '拖拽 ${from.isEmpty ? 'ref $fromRef' : from} → '
        '${to.isEmpty ? 'ref $toRef' : to}：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '拖拽失败：$e');
    }
  }

  Future<AgentToolResult> _select(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    // B2-1：ref 与 selector 二选一（见 _click 同口径）。
    final ref = '${args['ref'] ?? ''}'.trim();
    final value = '${args['value'] ?? ''}';
    if (selector.isEmpty && ref.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_select 缺少 selector 或 ref');
    }
    try {
      final out = await service.selectOption(
        selector,
        value,
        ref: ref.isEmpty ? null : ref,
      );
      return _untrusted(
        'browser_select:${service.currentUrl}',
        '选择 ${selector.isEmpty ? 'ref $ref' : selector}=$value：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '选择失败：$e');
    }
  }

  Future<AgentToolResult> _upload(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    // B2-1：ref 与 selector 二选一（见 _click 同口径）。
    final ref = '${args['ref'] ?? ''}'.trim();
    final file = '${args['file'] ?? args['path'] ?? ''}'.trim();
    if ((selector.isEmpty && ref.isEmpty) || file.isEmpty) {
      return AgentToolResult(
        ok: false,
        output: 'browser_upload 缺少 selector 或 ref/file',
      );
    }
    try {
      final out = await service.uploadFile(
        selector,
        file,
        ref: ref.isEmpty ? null : ref,
      );
      return _untrusted(
        'browser_upload:${service.currentUrl}',
        '上传 $file → ${selector.isEmpty ? 'ref $ref' : selector}：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '上传失败：$e');
    }
  }

  Future<AgentToolResult> _press(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final key = '${args['key'] ?? ''}'.trim();
    if (key.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_press 缺少 key');
    }
    // R6-B2：修饰键透传——pressKey 信封本就支持 modifiers（Ctrl+C/换行
    // 组合键），此前工具层恒丢致组合键不可表达。显式解析 ctrl/meta/shift。
    var modifiers = 0;
    final ctrl = args['ctrl'] == true || args['control'] == true;
    final meta = args['meta'] == true || args['cmd'] == true;
    final shift = args['shift'] == true;
    final alt = args['alt'] == true;
    if (ctrl || meta) modifiers |= (ctrl ? 2 : 0) | (meta ? 4 : 0);
    if (shift) modifiers |= 8;
    if (alt) modifiers |= 1;
    final rawMod = args['modifiers'];
    if (rawMod is int && rawMod >= 0 && rawMod <= 15) modifiers = rawMod;
    try {
      final out = await service.pressKey(key, modifiers: modifiers);
      return _untrusted(
        'browser_press:${service.currentUrl}',
        '按键 $key：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '按键失败：$e');
    }
  }

  Future<AgentToolResult> _scroll(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    // B2-1：ref 与 selector 二选一（见 _click 同口径）。
    final ref = '${args['ref'] ?? ''}'.trim();
    if (selector.isEmpty && ref.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_scroll 缺少 selector 或 ref');
    }
    try {
      final out = await service.scrollTo(
        selector,
        ref: ref.isEmpty ? null : ref,
      );
      return _untrusted(
        'browser_scroll:${service.currentUrl}',
        '滚动到 ${selector.isEmpty ? 'ref $ref' : selector}：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '滚动失败：$e');
    }
  }

  Future<AgentToolResult> _hover(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    final selector = '${args['selector'] ?? ''}'.trim();
    // B2-1：ref 与 selector 二选一（见 _click 同口径）。
    final ref = '${args['ref'] ?? ''}'.trim();
    if (selector.isEmpty && ref.isEmpty) {
      return AgentToolResult(ok: false, output: 'browser_hover 缺少 selector 或 ref');
    }
    // R2-M5：hover 同样 force 跳过遮挡检查。
    final force = args['force'] == true;
    try {
      final out = await service.hover(
        selector,
        force: force,
        ref: ref.isEmpty ? null : ref,
      );
      return _untrusted(
        'browser_hover:${service.currentUrl}',
        '悬停 ${selector.isEmpty ? 'ref $ref' : selector}：\n$out',
      );
    } catch (e) {
      return AgentToolResult(ok: false, output: '悬停失败：$e');
    }
  }

  Future<AgentToolResult> _dialog(Map<String, dynamic> args) async {
    if (service.currentUrl.isEmpty) {
      return AgentToolResult(ok: false, output: '尚未打开页面，先调用 browser_open');
    }
    // R5-05：默认拒——缺accept此前默认true误接受原生框，现默认false dismiss。
    final accept = args['accept'] == true;
    final promptText = args['promptText'] == null
        ? null
        : '${args['promptText']}';
    try {
      final out = await service.dialogAccept(accept, promptText: promptText);
      return _untrusted('browser_dialog:${service.currentUrl}', '对话框：\n$out');
    } catch (e) {
      return AgentToolResult(ok: false, output: '对话框处理失败：$e');
    }
  }
}
