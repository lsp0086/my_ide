part of 'browser_service.dart';

/// CDP 事件分发域：_buildCdpLocked 内原局部闭包 handleCdpEvent 抽出为实例方法；
/// 该闭包仅捕获 client/clientGen 两个局部（其余依赖均为实例字段），改由参数传入。
extension _BrowserServiceCdpHandlerExt on BrowserService {
  void _handleCdpEvent(Map<String, dynamic> e, CdpClient client, int clientGen) {
    if (clientGen != _serviceGen) return;
    if (!identical(_cdp, client)) return;
    try {
      final method = '${e['method'] ?? ''}';
      final params = (e['params'] as Map?) ?? const {};
      // Fix-N4：子会话（OOPIF/worker，flatten 带 sessionId）URL 归因——
      // targetInfo.url 优先，未知会话回退当前页；主会话事件口径不变。
      final sid = '${e['sessionId'] ?? ''}';
      final sessionUrl = sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
      final pageUrl = sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
      if (method == 'Tracing.dataCollected') {
        // C1：trace 事件流接线（Tracing.start 默认 ReportEvents 持续
        // 推送 dataCollected，params.value 为 traceEvents 数组）。累积
        // 受 20MB 字节预算约束，超限从头丢弃并标记 truncated。
        // A3-10：门控——未在采集期（traceEnd 之后/未 start）的迟到
        // dataCollected 一律丢弃，此前会把上次 trace 的残事件混进下次。
        if (_tracingEnabled) _collectTraceEvents(params);
      } else if (method == 'Tracing.tracingComplete') {
        // G-B6：ReturnAsStream 收流——tracingComplete 带 stream 句柄
        // （IO.StreamHandle），traceEnd 凭此 IO.read 分片收流；同时透出
        // dataLossOccurred 供排查（事件分支无副作用，直接结算等待者）。
        try {
          final stream = '${params['stream'] ?? ''}';
          final c = _traceStreamHandleReady;
          if (c != null && !c.isCompleted) c.complete(stream);
        } catch (_) {}
      } else if (method == 'Target.attachedToTarget') {
        // Fix-N4：flatten 子会话登记——OOPIF/worker 的 console/网络/异常
        // 事件按 sessionId 汇入同一分发逻辑（本 listener 下游各分支）。
        // G-B1：分支提取为 _onAttachedToTarget（单测可注入同口径事件）。
        _onAttachedToTarget(params.cast<String, dynamic>(), client);
      } else if (method == 'Target.detachedFromTarget') {
        // B3：子会话分离清理——删 sessionId→url 映射，迟到子会话事件
        // 不再按旧 URL 归因。enable 订阅（Runtime/Network/Log）无按
        // session 记录结构：一次性 CDP 调用无句柄可退订，Chrome 端会话
        // 关闭自动失效；该会话在途 pending 的 fail-fast 由 CdpClient
        // 检测 detach 后完成（_pendingSessions 侧通道；_pending 全局按
        // id 结算无 session 维度，见 chrome_cdp.dart）。
        _onDetachedFromTarget(e);
      } else if (method == 'Target.targetDestroyed' ||
          method == 'Target.targetCrashed') {
        // R7：target 消失清理——当前页 target 被关/崩溃时连接已死，
        // 复位 CDP 状态并广播，避免 UI 假"已连接"（与崩溃看门狗互补：
        // 看门狗管进程级退出，此处管单页 target 级消失）。
        // 非当前页 target 消失不影响当前连接，只记一条 console。
        final deadId = '${params['targetId'] ?? ''}';
        if (deadId.isNotEmpty && deadId == client.targetId) {
          console.pushText(
            'pageError',
            '当前页面 target 已${method == 'Target.targetCrashed' ? '崩溃' : '关闭'}，CDP 连接已复位，请重新 browser_open',
            url: _currentUrl.isEmpty ? null : _currentUrl,
          );
          unawaited(_resetCdp());
        } else {
          console.pushText(
            'warn',
            '其他页面 target 消失：$deadId',
            url: _currentUrl.isEmpty ? null : _currentUrl,
          );
        }
        // R2-09：发现缓存同步删——新页关闭后list不再含其id。
        _discoveredTargets.remove(deadId);
        // G-B3：带独立上下文的 target 消失即回收上下文（dispose 时机=关闭
        // 对应 target；closeTarget 显式路径已摘除映射时此处为 no-op）。
        final deadCtx = _contextByTarget.remove(deadId);
        if (deadCtx != null && deadCtx.isNotEmpty) {
          unawaited(() async {
            try {
              await client.send(
                'Target.disposeBrowserContext',
                {'browserContextId': deadCtx},
                const Duration(seconds: 3),
              );
            } catch (_) {}
          }());
        }
      } else if (method == 'Target.targetCreated') {
        // R2-09：新页发现——window.open/_blank/外部创建在轮询窗口外不可见。
        // 只收type=page且过webui过滤，与listTargets/selectPageTarget同口径；
        // created时url常为about:blank不冻结，后续targetInfoChanged更新；
        // 默认不自动切页不自动attach，只记缓存+一条nav提示。
        // R11-8-A 口径说明：此处收about:blank是发现语义（新页占位待回填），
        // 与selectPageTarget/listTargets连接语义（blank只做回退）不冲突：
        // 发现缓存收blank+后续回填真址，连接选择仍首选业务页。
        try {
          final ti = params['targetInfo'];
          if (ti is Map) {
            final nid = '${ti['targetId'] ?? ''}';
            final ntype = '${ti['type'] ?? ''}';
            final nurl = '${ti['url'] ?? ''}';
            final ntitle = '${ti['title'] ?? ''}';
            if (nid.isNotEmpty && ntype == 'page') {
              final lower = nurl.toLowerCase();
              final isWebUi =
                  lower.startsWith('chrome://') ||
                  lower.startsWith('devtools://') ||
                  lower.startsWith('chrome-extension://');
              if (!isWebUi) {
                _discoveredTargets[nid] = {'url': nurl, 'title': ntitle};
                if (_discoveredTargets.length > 50) {
                  _discoveredTargets.remove(_discoveredTargets.keys.first);
                }
                console.pushText(
                  'nav',
                  '发现新页面：${nurl.isEmpty ? nid : nurl}',
                  url: _currentUrl.isEmpty ? null : _currentUrl,
                );
              }
            }
          }
        } catch (_) {}
      } else if (method == 'Target.targetInfoChanged') {
        // B4：targetInfoChanged URL 兜底——bfcache/历史导航等
        // frameNavigated 之外的主 target URL 变更同步 _currentUrl。
        // 子会话（OOPIF，flatten 带 sessionId）与 targetId 不匹配的
        // info 变更经 mainTargetInfoChangedUrl 双重过滤不覆盖主 URL；
        // 与 frameNavigated 同走门禁+清缓冲导航流（R1-NavSeq单调序号，
        // 后到者恒覆盖，缓冲不双清）。
        // R1-BR2：同步回填_discoveredTargets——targetCreated常带about:blank，
        // 不回填则listTargets展示冻结且switchTarget不用缓存致新页切不过去。
        try {
          final ti = (e['params'] as Map?)?['targetInfo'];
          if (ti is Map) {
            final tid = '${ti['targetId'] ?? ''}';
            if (tid.isNotEmpty && _discoveredTargets.containsKey(tid)) {
              _discoveredTargets[tid] = {
                'url': '${ti['url'] ?? _discoveredTargets[tid]!['url'] ?? ''}',
                'title':
                    '${ti['title'] ?? _discoveredTargets[tid]!['title'] ?? ''}',
              };
            }
          }
        } catch (_) {}
        final infoUrl = CdpClient.mainTargetInfoChangedUrl(
          e,
          client.targetId,
        );
        if (infoUrl != null && infoUrl != _currentUrl) {
          _handleMainNavUrl(infoUrl);
        }
      } else if (method == 'Page.javascriptDialogOpening') {
        // 原生 alert/confirm 卡 load 与 evaluate：此前无监听，页面弹框即卡 20s 超时。
        // chrome-devtools-mcp 口径：自动 dismiss 并记一条 console 归因。
        // E1：抽为 _onDialogOpening（测试可见注入）——type/message 记
        // console（[dialog] type: msg），URL 归因按会话口径（子会话
        // OOPIF 用 targetInfo.url），dismiss 带原 sessionId（flatten
        // 信封路由，不误发主连接）。
        _onDialogOpening(e);
      } else if (method == 'Fetch.authRequired') {
        // C3：401/407 挑战——按 origin 决策回填 Basic 凭据或取消。
        _onAuthRequired(e);
      } else if (method == 'Fetch.requestPaused') {
        // C3：patterns 只拦目标 origin 请求，一律放行防加载挂死。
        _onRequestPaused(e);
      } else if (method == 'Page.fileChooserOpened') {
        // C4：文件选择器拦截——回填工作区文件或记提示，原生框不弹出。
        _onFileChooserOpened(e);
      } else if ((method == 'Page.frameNavigated' ||
              method == 'Page.navigatedWithinDocument') &&
          sid.isEmpty) {
        // Fix-N4：仅主会话导航切页——子会话（OOPIF）根帧 parentId 亦为空，
        // 若放行将改写 _currentUrl/清缓冲串页，故带 sessionId 一律忽略。
        // B2：主帧导航处理（含 bfcache 恢复识别）抽为 _onMainNavEvent，
        // 单测经 handleMainNavEventForTest 注入同口径事件。
        _onMainNavEvent(method, params.cast<String, dynamic>());
      } else if (method == 'Runtime.executionContextCreated') {
        // B2-01 上下文归因登记：context(auxData.frameId/url) 记表，
        // console 无 stack 时按 executionContextId 回查 iframe url。
        // C4/C5：同时登记 uniqueContextId 与 frameId——evaluate 优先传
        // uniqueContextId 防 contextId 跨进程复用错域执行；frameId 表
        // 为存活表，destroyed/Remove 后 evaluate 得可读错误。
        // C6：仅主会话（sid 为空）登记——flatten 子会话（OOPIF/worker）
        // 的 contextId 空间与主会话独立且可同号，全局一表混写时同号
        // 互相覆盖（eval 凭 uniqueContextId 错域执行/误报销毁）；子会话
        // 归因走 _sessionUrls，不经本表。
        if (sid.isEmpty) {
          try {
            final ctx = params['context'];
            if (ctx is Map) {
              final id = '${ctx['id'] ?? ''}';
              final aux = ctx['auxData'];
              var url = '';
              var fid = '';
              if (aux is Map) {
                url = '${aux['frameUrl'] ?? aux['url'] ?? ''}';
                fid = '${aux['frameId'] ?? ''}';
              }
              url = url.isEmpty ? '${ctx['origin'] ?? ''}' : url;
              final unique = '${ctx['uniqueContextId'] ?? ''}';
              if (id.isNotEmpty && url.isNotEmpty) {
                if (_contextUrls.length >= 500) {
                  final oldest = _contextUrls.keys.first;
                  _contextUrls.remove(oldest);
                  _contextUrlGens.remove(oldest);
                  _ctxUniqueById.remove(oldest);
                  _ctxFrameById.remove(oldest);
                }
                _contextUrls[id] = url;
                // R5-B1同口径：登记即记当前世代。
                _contextUrlGens[id] = _serviceGen;
              }
              // C4：uniqueContextId（可能无 url 也有 unique id）。
              if (id.isNotEmpty && unique.isNotEmpty) {
                _ctxUniqueById[id] = unique;
              }
              // C5：contextId→frameId 存活表。
              if (id.isNotEmpty && fid.isNotEmpty) {
                _ctxFrameById[id] = fid;
              }
            }
          } catch (_) {}
        }
      } else if (method == 'Runtime.executionContextDestroyed') {
        // C6：仅主会话销毁同步（同上口径——子会话同号销毁不得误删
        // 主会话存活上下文）。
        if (sid.isEmpty) {
          try {
            final eid = '${params['executionContextId'] ?? ''}';
            _contextUrls.remove(eid);
            _contextUrlGens.remove(eid);
            // C5：销毁同步清存活/unique 表，evaluate 即得可读错误。
            _ctxUniqueById.remove(eid);
            _ctxFrameById.remove(eid);
          } catch (_) {}
        }
      } else if (CdpClient.executionContextsClearedOf(e)) {
        // D7：判定收敛到 CdpClient.executionContextsClearedOf（单测同源，
        // method+仅主会话双条件在函数内）。
        // Fix-N4：仅主会话清空上下文表——子会话 contextsCleared 会误删
        // 主页面 iframe 归因（全局一表，按代失效见 R5-B1）。
        // B3-01：SPA 清上下文后旧 ctx 残留，console 误归因旧 iframe。
        try {
          _contextUrls.clear();
          _contextUrlGens.clear();
          // C5：同口径全清。
          _ctxUniqueById.clear();
          _ctxFrameById.clear();
        } catch (_) {}
      } else if (method == 'Network.requestWillBeSentExtraInfo' ||
          method == 'Network.responseReceivedExtraInfo') {
        // C9：CORS 精确归因数据源——笼统 net::ERR_FAILED 的真实原因在
        // experimental extraInfo 事件（responseReceivedExtraInfo 的
        // corsErrorStatus/blockedReason）。按 requestId 缓存（有界 500），
        // loadingFailed 命中即映射可读归因，缺失兜底原文。
        // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Network/#type-CorsErrorStatus
        // + https://github.com/puppeteer/puppeteer/issues/6810 。
        try {
          final rid = '${params['requestId'] ?? ''}';
          if (rid.isNotEmpty) {
            if (_extraInfoByReq.length >= 500) {
              _extraInfoByReq.remove(_extraInfoByReq.keys.first);
            }
            final cors = params['corsErrorStatus'];
            final blocked = params['blockedReason'];
            _extraInfoByReq[rid] = {
              if (cors is Map) 'cors': Map<String, dynamic>.from(cors),
              if (blocked is List) 'blocked': List<String>.from(
                blocked.map((b) => '$b'),
              ),
            };
          }
        } catch (_) {}
      } else if (method == 'Page.frameDetached') {
        // C6：site isolation 下跨域 iframe Swap 换 frameId（Puppeteer
        // frameSwapped 语义）——reason=Swap 保留语义帧（上下文/归因表
        // 不清，后续 frameAttached/executionContextCreated 自然重绑），
        // 仅 Remove/SwapAndRemove 清该 frame 的上下文条目。
        // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-frameDetached 。
        try {
          final fid = '${params['frameId'] ?? ''}';
          final reason = '${params['reason'] ?? ''}'.toLowerCase();
          if (fid.isNotEmpty && reason != 'swap') {
            final doomed = _ctxFrameById.entries
                .where((e) => e.value == fid)
                .map((e) => e.key)
                .toList();
            for (final id in doomed) {
              _ctxFrameById.remove(id);
              _ctxUniqueById.remove(id);
              _contextUrls.remove(id);
              _contextUrlGens.remove(id);
            }
          }
        } catch (_) {}
      } else if (method == 'Runtime.consoleAPICalled') {
        // console.log 全量通道：args 为 RemoteObject 数组，取 value/description。
        final args = params['args'];
        final buf = StringBuffer();
        if (args is List) {
          for (final a in args) {
            if (a is Map) {
              final v = a['value'] ?? a['description'];
              buf.write('${v ?? ''} ');
            } else {
              buf.write('$a ');
            }
          }
        }
        // 类型归一：CDP 用 warning，内嵌钩子用 warn，errorsOnly 按 warn/error 收敛，
        // 此前 warning/warn 与 errorTypes 对不上，错误过滤漏事件。
        // URL 归因：此前 console.log 无 url，跨页/iframe 报错无法定位。
        // 取 stackTrace 首帧 url，回退当前页（Puppeteer location 口径）。
        String? logUrl;
        final stack = params['stackTrace'];
        // 事件缺口修复：此前只取首帧 URL 丢 stack，多帧堆栈丢失无法定位。
        // 首帧归因 URL，其余帧拼进正文（最多 5 帧防刷屏）。
        String stackSuffix = '';
        if (stack is Map) {
          final frames = stack['callFrames'];
          if (frames is List && frames.isNotEmpty) {
            final first = frames.first;
            if (first is Map) {
              final u = '${first['url'] ?? ''}';
              if (u.isNotEmpty) logUrl = u;
            }
            final extra = <String>[];
            for (var i = 0; i < frames.length && extra.length < 5; i++) {
              final f = frames[i];
              if (f is Map) {
                final u = '${f['url'] ?? ''}';
                final fn = '${f['functionName'] ?? ''}';
                final ln = '${f['lineNumber'] ?? ''}';
                if (u.isNotEmpty || fn.isNotEmpty) {
                  extra.add('  at ${fn.isEmpty ? '?' : fn} $u:$ln');
                }
              }
            }
            if (extra.isNotEmpty) {
              stackSuffix = '\n${extra.join('\n')}';
            }
          }
        }
        // Fix-N4：回退归因按会话页面 URL（OOPIF/worker 用 targetInfo.url）。
        logUrl ??= pageUrl.isEmpty ? null : pageUrl;
        final rawType = '${params['type'] ?? 'log'}';
        // R1-BR2：console归因统一——此前console分支空归因回退_currentUrl，
        // 而Log/exception置null+正文缀当前页，同iframe错误分组错位。
        // 现：console同样空归因置null+堆栈正文缀当前页，不伪造归因。
        // warning→warn 归一：与 errorTypes/errorsOnly 对齐。
        final logType = rawType == 'warning' ? 'warn' : rawType;
        // B2-01 iframe 归因：stack 首帧 url 为空时回退 executionContext，
        // 同页多 iframe 的 console 不再全串主页面（Target flat 口径）。
        // R5-B1：按代失效——此前无cleared事件时旧iframe url永久覆盖新页log。
        // 现_contextUrls记(url,gen)，切页/清缓冲即换代，旧代回查失效。
        if ((logUrl == null || logUrl == _currentUrl) &&
            '${params['executionContextId'] ?? ''}'.isNotEmpty) {
          final ctxUrl = _contextUrls['${params['executionContextId']}'];
          if (ctxUrl != null &&
              ctxUrl.isNotEmpty &&
              _contextUrlGens['${params['executionContextId']}'] ==
                  _serviceGen) {
            logUrl = ctxUrl;
          }
        }
        final body = buf.toString().trim().isEmpty
            ? '(空 console 参数)'
            : buf.toString().trim();
        // R7-2：console 体截断——chrome-devtools-mcp list_console_messages 口径
        // 对大对象分页/截断，此前大 console.log 无界进环撑爆上下文。
        // R1-BR2统一口径：空归因(url仍无stack/ctx)置null+正文缀当前页，
        // 与Log/exception分支一致，不伪造主页面归因。
        var clippedBody = body.length > 4000
            ? '${body.substring(0, 4000)}…（已截断，共 ${body.length} 字符）$stackSuffix'
            : '$body$stackSuffix';
        String? finalLogUrl = logUrl;
        if ((finalLogUrl == null || finalLogUrl == pageUrl) &&
            stackSuffix.isEmpty &&
            pageUrl.isNotEmpty) {
          // 无stack定位依据且回退到会话页面：归因置null，正文缀上下文。
          finalLogUrl = null;
          clippedBody = '$clippedBody\n（当前页：$pageUrl）';
        }
        console.pushText(logType, clippedBody, url: finalLogUrl);
      } else if (method == 'Debugger.scriptFailedToParse') {
        // R2-10：语法错可观测——V8解析失败不走exceptionThrown，
        // 此前console无条。记pageError，归因优先url空回退当前页。
        // D7：url 提取收敛到 CdpClient.scriptParseUrl（单测同源）。
        try {
          final sUrl = CdpClient.scriptParseUrl(e) ?? '';
          final sLine = '${params['startLine'] ?? ''}';
          final sCol = '${params['startColumn'] ?? ''}';
          final lang = '${params['scriptLanguage'] ?? ''}';
          final sid2 = '${params['scriptId'] ?? ''}';
          var body =
              '脚本解析失败${lang.isEmpty ? '' : '（$lang）'}：${sUrl.isEmpty ? '（未知URL）' : sUrl}${sLine.isEmpty ? '' : ':$sLine'}${sCol.isEmpty ? '' : ':$sCol'}${sid2.isEmpty ? '' : '（scriptId=$sid2）'}';
          if (sUrl.isEmpty && pageUrl.isNotEmpty) {
            // 空归因不伪造主页面：正文缀当前页（同Log/console口径）。
            body = '$body\n（当前页：$pageUrl）';
          }
          console.pushText(
            'pageError',
            body,
            url: sUrl.isEmpty ? null : sUrl,
          );
        } catch (_) {}
      } else if (method == 'Audits.issueAdded') {
        // R2-10：CSP结构化可观测——Log只有文本，blockedURL/directive只在Issue。
        // 仅收ContentSecurityPolicyIssue防刷屏；未知violationType原样透出。
        // D7：URL 归因收敛到 CdpClient.auditsAffectedUrl（单测同源，
        // CSP 口径 sourceCodeLocation.url 优先、其次 blockedURL，与
        // 手写 locUrl??blocked 一致）。
        try {
          final issue = params['issue'];
          if (issue is Map &&
              '${issue['code'] ?? ''}' == 'ContentSecurityPolicyIssue') {
            final details = issue['details'];
            var blocked = '';
            var directive = '';
            var vtype = '';
            var reportOnly = false;
            if (details is Map) {
              final csp = details['contentSecurityPolicyIssueDetails'];
              if (csp is Map) {
                blocked = '${csp['blockedURL'] ?? ''}';
                directive = '${csp['violatedDirective'] ?? ''}';
                vtype = '${csp['violationType'] ?? ''}';
                reportOnly = csp['isReportOnly'] == true;
              }
            }
            final body =
                'CSP${reportOnly ? '（仅报告未阻断）' : '（已阻断）'}：${directive.isEmpty ? '' : '$directive '}${blocked.isEmpty ? '' : '拦截 $blocked '}${vtype.isEmpty ? '' : '[$vtype]'}'
                    .trim();
            console.pushText(
              reportOnly ? 'warn' : 'pageError',
              body,
              url: CdpClient.auditsAffectedUrl(e),
            );
          }
        } catch (_) {}
      } else if (method == 'Console.messageAdded') {
        // R1-10：Console.messageAdded并入错误流——worker/早期console
        // 不走consoleAPICalled，此前全漏。口径：error级进console环，
        // 其余按类型直推，与consoleAPICalled同截断（4k）同归因（当前页）。
        // R1-B6：空归因缀当前页后缀——与Log/exception分支同口径，
        // 否则tailWhere(urlContains)下空归因条目永久召回不到。
        try {
          final msg = params['message'];
          if (msg is Map) {
            final level = '${msg['level'] ?? 'log'}';
            final text = '${msg['text'] ?? ''}'.trim();
            final mUrl = '${msg['url'] ?? ''}';
            final sid = '${e['sessionId'] ?? ''}';
            final sessionUrl =
                sid.isEmpty ? '' : (_sessionUrls[sid] ?? '');
            final pageUrl =
                sessionUrl.isNotEmpty ? sessionUrl : _currentUrl;
            if (text.isNotEmpty) {
              var clipped = text.length > 4000
                  ? '${text.substring(0, 4000)}…（已截断，共 ${text.length} 字符）'
                  : text;
              if (mUrl.isEmpty) {
                clipped = pageUrl.isEmpty
                    ? clipped
                    : '$clipped\n  at $pageUrl\n（当前页：$pageUrl）';
              } else {
                clipped = '$clipped\n  at $mUrl';
              }
              console.pushText(
                level,
                clipped,
                url: mUrl.isEmpty ? null : mUrl,
              );
            }
          }
        } catch (_) {}
      } else if (method == 'Log.entryAdded') {
        // E2：抽为 _onLogEntryAdded（测试可见注入）——url 归因/
        // networkRequestId 关联/堆栈帧/level 映射口径不变。
        _onLogEntryAdded(e);
      } else if (method == 'Runtime.exceptionThrown') {
        // E3：抽为 _onExceptionThrown（测试可见注入）——补
        // preview/className 序列化与 stackTrace 帧拼入。
        _onExceptionThrown(e);
      } else if (method == 'Network.requestWillBeSent') {
        // 唯一带完整 URL 的起点：必须先存表，loadingFailed 回查用。
        // D7：字段解析收敛到 CdpClient.requestWillBeSentInfo（单测同源，
        // url 仅取 request.url，缺失即跳过登记与手写口径一致）；
        // frameId/loaderId 一并透出但生产不建 loader/frame→URL 映射
        // （注释宣称已修正，见提取函数 doc）。
        // R9-T1：重定向链保留初址——同requestId复用时此前直接覆盖，
        // loadingFailed回查只剩终址，初址失败归因丢失。现首次命中保留。
        // R5-E9：同 requestId 连续 willBeSent 且带 redirectResponse 即一跳
        // （puppeteer NetworkManager 口径），旧 url 追加进链，最终归因原始。
        final info = CdpClient.requestWillBeSentInfo(e);
        final reqId = info?.id ?? '';
        final url = info?.url ?? '';
        if (info != null && reqId.isNotEmpty && url.isNotEmpty) {
          final redirectResp = params['redirectResponse'];
          // C7：在途登记（redirectResponse 到达即上一跳已结束，此处为
          // 新一跳在途；terminal 事件注销）。
          if (redirectResp is! Map) {
            if (_inflightRequests.length >= 500) {
              _inflightRequests.remove(_inflightRequests.keys.first);
            }
            _inflightRequests[reqId] = url;
          }
          if (redirectResp is Map && _requestUrls.containsKey(reqId)) {
            final chain = _redirectChains.putIfAbsent(
              reqId,
              () => [_requestUrls[reqId]!],
            );
            final prev = '${(redirectResp['url'] ?? '')}';
            final cur = _requestUrls[reqId]!;
            if (prev.isNotEmpty && (chain.isEmpty || chain.last != prev)) {
              chain.add(prev);
            }
            if (chain.isEmpty || chain.last != cur) chain.add(cur);
          }
          if (!_requestUrls.containsKey(reqId)) {
            if (_requestUrls.length >= BrowserService._maxTrackedRequests) {
              final oldest = _requestUrls.keys.first;
              _requestUrls.remove(oldest);
              _redirectChains.remove(oldest);
            }
            _requestUrls[reqId] = url;
          }
          // B14：全量请求表登记请求发起（含成功请求）——requestWillBeSent
          // 是唯一带完整 URL 的起点，全量表从这里开始记，后续
          // responseReceived 补状态码、loadingFailed 补错误文本。
          // 重定向跳只登记一次（后续跳的初址保留在 _redirectChains，
          // 全量表以原始 url 为准，避免一条请求变多条）。
          if (redirectResp is! Map) {
            requests.add(reqId, url);
          }
          // R-DOC-ATTR：登记请求所属文档 URL（有界 500 防泄漏）。
          final docUrl = '${params['documentURL'] ?? ''}'.trim();
          if (docUrl.isNotEmpty) {
            if (_docUrlByReq.length >= 500) {
              _docUrlByReq.remove(_docUrlByReq.keys.first);
            }
            _docUrlByReq[reqId] = docUrl;
          }
        }
      } else if (method == 'Network.responseReceived') {
        // HTTP 错误状态不会触发 loadingFailed，只能这里判 status>=400。
        // B4：附 response 体前 2k 截断（chrome-devtools-mcp read_network 口径），
        // 失败静默跳过不断链（getResponseBody 对 redirect/无体抛错）。
        // 竞态修复：getResponseBody 必须在 loadingFinished 后取，否则
        // “No data found for resource”；此处只记状态，体在 loadingFinished 补。
        final resp = params['response'];
        final status = resp is Map ? (resp['status'] as num?)?.toInt() : null;
        final reqId = '${params['requestId'] ?? ''}';
        final resourceType = '${params['type'] ?? ''}';
        // B14：所有响应（含成功）都补状态码——成功请求不进
        // networkFailures，全量表只在 responseReceived 补一次。
        if (status != null && reqId.isNotEmpty) {
          requests.markResponse(
            reqId,
            statusCode: status,
            resourceType: resourceType.isEmpty ? null : resourceType,
            url: resp is Map ? '${resp['url'] ?? ''}' : null,
          );
        }
        if (status != null && status >= 400) {
          // G2-4：responseReceived 同带 type（ResourceType），HTTP 4xx/5xx
          // 条目入库供 type 过滤（与 loadingFailed 同口径）。
          // 假归因修复：映射缺失时不再把 requestId（如 123.5）当 URL 写入，
          // 用当前页归因，排查不被假 URL 污染。
          var url = resp is Map ? '${resp['url'] ?? ''}' : '';
          if (url.isEmpty && reqId.isNotEmpty) {
            // R5-E9：重定向链头（原始 url）优先——response.url 是终跳，
            // 初址失败排查要看起点。
            final chain = _redirectChains[reqId];
            url = (chain != null && chain.isNotEmpty)
                ? chain.first
                : (_requestUrls[reqId] ?? '');
          }
          // R12R5：回退归因打标记——映射缺失用当前页兜底时正文带
          // “（归因回退）”，CDN失败不再裸标主页面误导排查。
          // R2-BR3：存储不伪造——回退时networkFailures存空URL，
          // 展示层(format)再回退当前页，存储归因不污染主页面。
          var fallback = false;
          if (url.isEmpty) {
            url = pageUrl;
            // Fix-N4：子会话已知 target URL 属真实归因不计回退；
            // 仅未知会话回退当前页才打标记（R12R5/R2-BR3 口径不变）。
            fallback = url.isNotEmpty && sessionUrl.isEmpty;
          }
          final shown = fallback ? '$url（归因回退）' : url;
          // R2-BR3：回退即存空，展示才回退。
          networkFailures.push(fallback ? '' : url, 'HTTP $status',
              resourceType: resourceType);
          console.pushText(
            'pageError',
            'HTTP $status $shown',
            url: url.isEmpty ? null : url,
          );
          if (reqId.isNotEmpty) {
            // R4：四结构同步淘汰——此前满200只删Set，三Maps随requestId
            // 无限增长，长会话内存泄漏。现淘汰最旧一条四结构全清。
            if (_pendingErrorBodies.length >= 200) {
              final oldest = _pendingErrorBodies.first;
              _pendingErrorBodies.remove(oldest);
              _pendingErrorBodyUrls.remove(oldest);
              _pendingErrorBodyPages.remove(oldest);
              _pendingErrorBodyGens.remove(oldest);
            }
            // R2-2：记下归属快照（url+取体时页URL+loader代次）——SPA切页窗口内
            // 旧页 getResponseBody 晚到时不再串入新页 console。
            _pendingErrorBodies.add(reqId);
            _pendingErrorBodyUrls[reqId] = url.isEmpty ? _currentUrl : url;
            _pendingErrorBodyPages[reqId] = _currentUrl;
            _pendingErrorBodyGens[reqId] = clientGen;
          }
        }
      } else if (method == 'Network.loadingFinished') {
        final reqId = '${params['requestId'] ?? ''}';
        // C7：terminal 注销在途表。
        _inflightRequests.remove(reqId);
        // C9：extraInfo 缓存随终态释放。
        _extraInfoByReq.remove(reqId);
        // R5-E9：映射生命周期收敛——终态事件后删除 requestId 映射与重定向
        // 链，长会话不再靠 2000 上限淘汰。错误体路径仍需映射做 snapUrl
        // 兜底（见下 _requestUrls[reqId]），故只在非错误体路径删除。
        // R2-11：删前先葬墓碑——晚到Log先查活表再查墓碑，不再归因回退。
        final isErrorBody =
            reqId.isNotEmpty && _pendingErrorBodies.contains(reqId);
        if (!isErrorBody) {
          final tomb = _requestUrls[reqId];
          if (tomb != null && tomb.isNotEmpty) _buryRequestUrl(reqId, tomb);
          _requestUrls.remove(reqId);
          _redirectChains.remove(reqId);
        }
        if (reqId.isNotEmpty && _pendingErrorBodies.remove(reqId)) {
          final cached = _cdp;
          // 世代绑定：重连后旧 client 的晚到 body 不得写进新页 console。
          final bodyGen = clientGen;
          // R2-2：归属快照——取体完成后再比对，切页/换代即丢弃不串页。
          final wantUrl = _pendingErrorBodyUrls.remove(reqId) ?? '';
          final wantPage = _pendingErrorBodyPages.remove(reqId) ?? '';
          final wantGen = _pendingErrorBodyGens.remove(reqId);
          if (cached != null && identical(cached, client)) {
            // R5-E9：错误体异步取体已派出，快照已记 wantUrl，映射不再需要，
            // 此处释放（长会话映射只增不减的最后一处缺口）。
            _requestUrls.remove(reqId);
            _redirectChains.remove(reqId);
            unawaited(() async {
              try {
                final body = await cached
                    .send('Network.getResponseBody', {'requestId': reqId})
                    .timeout(const Duration(seconds: 5));
                if (bodyGen != _serviceGen || !identical(_cdp, client)) {
                  return;
                }
                // 切页后晚到丢弃：取体期间 _currentUrl 已变即旧页体串新页。
                if (wantGen != null && wantGen != _serviceGen) {
                  return;
                }
                if (wantPage.isNotEmpty && wantPage != _currentUrl) {
                  return;
                }
                // B2-03：超大 body 无界进内存，大文件下载页直接 OOM。
                // R5-E9：base64 先解码再看——旧实现 base64 直接丢弃记一条，
                // 文本类 body（base64 编码传输）永远看不到。解码失败才跳过。
                var snippet = '${body['body'] ?? ''}';
                if (body['base64Encoded'] == true) {
                  try {
                    final decoded = utf8.decode(
                      base64Decode(snippet),
                      allowMalformed: true,
                    );
                    snippet = decoded;
                  } catch (_) {
                    return;
                  }
                }
                // R2-2：归因优先用快照 url，不再用可能已被 clear 的 _requestUrls
                // 回查（切页 clear 后回退 _currentUrl 即新页，旧体串新页）。
                final snapUrl = wantUrl.isNotEmpty
                    ? wantUrl
                    : (_requestUrls[reqId] ?? '');
                if (snippet.length > 512 * 1024) {
                  final bodyShow = snapUrl.isEmpty ? pageUrl : snapUrl;
                  console.pushText(
                    'warn',
                    '响应体过大已跳过（${snippet.length} 字符）：$bodyShow',
                    url: bodyShow.isEmpty ? null : bodyShow,
                  );
                  return;
                }
                if (snippet.isNotEmpty) {
                  if (snippet.length > 2000) {
                    snippet = '${snippet.substring(0, 2000)}…';
                  }
                  final bodyShow = snapUrl.isEmpty ? pageUrl : snapUrl;
                  console.pushText(
                    'pageError',
                    '响应体 $bodyShow：$snippet',
                    url: bodyShow.isEmpty ? null : bodyShow,
                  );
                }
              } catch (e) {
                // C3：跨进程导航后历史 body 缓冲被清——"No resource with
                // given identifier found" 映射为可读归因，不再静默吞掉
                // （puppeteer #2176 口径：body 读取延迟到 loadingFinished
                // 已在上方实现；本兜底覆盖 site-isolation 换进程场景）。
                final msg = '$e';
                if (msg.contains('No resource with given identifier')) {
                  final bodyShow = wantUrl.isNotEmpty
                      ? wantUrl
                      : (pageUrl.isEmpty ? '' : pageUrl);
                  console.pushText(
                    'pageError',
                    '响应体不可回读（跨进程导航后缓冲已清）：$bodyShow',
                    url: bodyShow.isEmpty ? null : bodyShow,
                  );
                }
              }
            }());
          }
        }
      } else if (method == 'Network.loadingFailed') {
        // C1：分支提取为 _onLoadingFailed——单测可直灌事件 + 导航中断
        // 去噪（goto(A) 后立即 goto(B)，A 的请求全部 aborted 误报）。
        _onLoadingFailed(
          params.cast<String, dynamic>(),
          pageUrl: pageUrl,
          sessionUrlKnown: sessionUrl.isNotEmpty,
          client: client,
          clientGen: clientGen,
        );
      } else if (method == 'Network.webSocketFrameError' ||
          method == 'Network.webSocketHandshakeResponseReceived') {
        // R4-12：WS 事件记 console（与 Log.entryAdded 同截断同归因）。
        // 来源 https://chromedevtools.github.io/devtools-protocol/tot/Network/#event-webSocketFrameError 。
        // 校验：连失败 WS 端点的测试页，console 应见 WS 错误条目。
        try {
          if (method == 'Network.webSocketFrameError') {
            final wsErr = '${params['errorMessage'] ?? ''}';
            if (wsErr.isNotEmpty && !wsErr.contains('ERR_ABORTED')) {
              console.pushText(
                'pageError',
                '[ws] $wsErr',
                url: pageUrl.isEmpty ? null : pageUrl,
              );
            }
          } else {
            final resp = params['response'];
            final status = resp is Map
                ? (resp['status'] as num?)?.toInt()
                : null;
            // WS 握手成功为 101（Switching Protocols），非 101/2xx 才记错：
            // 按字面“非 2xx”会把每次成功握手都记一条误报。
            if (status != null &&
                status != 101 &&
                (status < 200 || status >= 300)) {
              final wsUrl = '${params['url'] ?? ''}';
              console.pushText(
                'pageError',
                '[ws] 握手失败 HTTP $status ${wsUrl.isEmpty ? '' : wsUrl}'.trim(),
                url: pageUrl.isEmpty ? null : pageUrl,
              );
            }
          }
        } catch (_) {}
      } else if (method == 'Network.webSocketCreated' ||
          method == 'Network.webSocketFrameReceived' ||
          method == 'Network.webSocketFrameSent' ||
          method == 'Network.webSocketClosed') {
        // B7：WS 生命周期/帧记账（提取为方法供测试钩子直灌）。
        _onWebSocketEvent(method, params.cast<String, dynamic>(), pageUrl);
      } else if (method == 'Page.windowOpen') {
        // R4-15：window.open 记 nav 提示（来源
        // https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-windowOpen）。
        // 校验：window.open 被拦截的测试页，控制台应见提示。
        try {
          final wurl = '${params['url'] ?? ''}';
          final wname = '${params['windowName'] ?? ''}';
          console.pushText(
            'nav',
            'window.open${wname.isEmpty ? '' : '[$wname]'}${wurl.isEmpty ? '' : '：$wurl'}',
            url: pageUrl.isEmpty ? null : pageUrl,
          );
        } catch (_) {}
      } else if (method == 'Runtime.bindingCalled') {
        // GB1：页面→Agent 回报通道——window.<bindingName>(payload) 调用经
        // Runtime.addBinding 注册后以本事件回流（仅注册过的 binding 会产生）。
        // payload 为页面侧脚本产物（不可信数据），按 UNTRUSTED_DATA 围栏包进
        // console（复用 lib/ai/external_content.dart 口径，与工具输出同源）。
        _onBindingCalled(params.cast<String, dynamic>(), pageUrl);
      } else if (method == 'Input.dragIntercepted') {
        // GB5：setInterceptDrags 拦截到的真实拖拽——DragData 结构化载荷缓存，
        // drag() 结构化路径无显式 dataTransfer 时优先复用（真拖放口径），
        // 读取即清；仅主会话事件入缓存（子会话拖拽不适用于当前页结构化链）。
        if (sid.isEmpty) {
          final data = params['data'];
          if (data is Map && data.isNotEmpty) {
            _interceptedDragData = Map<String, dynamic>.from(data);
          }
        }
      } else if (method == 'Browser.downloadWillBegin' ||
          method == 'Download.willBegin' ||
          method == 'Browser.downloadProgress' ||
          method == 'Download.progress') {
        // R4-04/G-B5：下载事件提取为 _onDownloadEvent（单测可直灌）——
        // willBegin 记 suggestedFilename，完成后拼绝对路径写 console。
        _onDownloadEvent(method, params.cast<String, dynamic>(), pageUrl);
      }
    } catch (_) {}
  }
}
