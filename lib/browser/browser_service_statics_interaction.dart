part of 'browser_service.dart';

  /// R2-M5 遮挡检查 JS（A3-1 穿透口径）：目标元素与命中点归属都走
  /// [CdpClient.pierceHelperJs]——命中 IFRAME/FRAME 宿主时按宿主 bbox
  /// 偏移下钻 contentDocument 递归归属（A3-1：iframe 内元素
  /// elementFromPoint 只返回 IFRAME 宿主致误判 covered），目标元素经
  /// __pierceQueryInfo 解析（主文档 querySelector 不递归 open shadow
  /// root 边界）。frame 上下文参与比对，不同 frame 的同名元素不算 HIT。
  /// payload 经 b64 进 JS（与 fillEditableJs 同口径，selector 含引号不断裂）。
  /// 返回 HIT=通过；covered/unstable=被遮挡/不稳定；err=检查失败降级放行。

String occlusionCheckJsForTest(String rawPayload, double x, double y) {
    // R11R1-01：外层箭头带形参——此前前缀为`()=>{`无参却以`($x,$y)`调用，
    // 实参被丢弃且`x/y`为全局未定义，必ReferenceError降级放行为err。
    // 现把前缀替换为`((x,y)=>{`，后缀实参正常形参化（与fill/select同b64口径）。
    final rawPrefix = _jsPayloadPrefixFromJson(rawPayload);
    final prefix = rawPrefix.replaceFirst('(()=>{', '((x,y)=>{');
    return '$prefix'
        '${CdpClient.pierceHelperJs}'
        // 归属描述：frame 名 + 祖先链（shadow 子节点 parentElement 为 null，
        // 仅剩自身 tag，不同 root 的同 tag 元素由 frame 名区分）。
        'function desc(el,ft){var s=[];var n=el;while(n&&s.length<4){'
        's.push(n.tagName||(n.nodeName||"?").toString());n=n.parentElement;}'
        'return (ft||"main")+":"+s.join(">");}'
        'function sameBox(p,q){if(!p||!q) return p==q;'
        'return Math.abs(p.x-q.x)<1&&Math.abs(p.y-q.y)<1&&'
        'Math.abs(p.width-q.width)<1&&Math.abs(p.height-q.height)<1;}'
        'var info=null;try{info=__pierceQueryInfo(a.s);}catch(_){}'
        'var el=info?info.el:null;var eft=info&&info.doc&&info.doc!==document?"iframe":"main";'
        'var r0=null;try{if(el) r0=el.getBoundingClientRect().toJSON();}catch(_){}'
        'return new Promise(function(res){requestAnimationFrame(function(){'
        'requestAnimationFrame(function(){'
        // A3-1：命中点归属走 pierce——IFRAME/FRAME 宿主自动下钻到子文档。
        'var at=null;try{at=__pierceAtPoint(x,y);}catch(_){}'
        'var second=at?at.el:null;var hft=at&&at.doc&&at.doc!==document?"iframe":"main";'
        'var r1=null;try{if(el) r1=el.getBoundingClientRect().toJSON();}catch(_){}'
        'if(!sameBox(r0,r1)) res("unstable:bbox变化");'
        'else if(!second) res("covered:空命中");'
        'else if(el&&(second===el||(el.contains&&el.contains(second))))'
        ' res("HIT:"+desc(second,hft));'
        'else res("covered:"+desc(second,hft)+"!="+(el?desc(el,eft):"null"));'
        '});});});'
        '}catch(e){return Promise.resolve("err:"+e);}})($x,$y)';
  }


  /// D1/D2 共用：原生点击三连——mouseMoved 悬停归位（R6-2：hover/命中
  /// 判定按最后移动点）→ mousePressed → mouseReleased（left，clickCount=1）。
  /// R3-12：点击后导航关联——慢链点击后读新页：click 内已等 load（B5-01
  /// 的点击后短等），外层 read/snapshot 同步走半成品等 body 口径，不再读旧页。
  /// 第4轮N4：删平行实现 JS——live 代码（click/fill/
  /// drag/select/hover）全走 CdpClient.waitForSelector，此字符串从不执行，
  /// 仅测试引用且与 waitForSelector 共享 window 全局变量有交叉污染隐患。

  /// R3-12：多 frame 读——Page.getFrameTree 枚举 frame，经 Runtime.callFunctionOn
  /// 分片拼 outerHTML，不再只读主 frame。

String frameOuterHtmlJsForTest() =>
      "(function(){try{return document.documentElement?document.documentElement.outerHTML:'';}catch(e){return '';}})()";


  /// R3-12：下载管理——接管下载到工作区目录，progress 经
  /// Download.willBegin/progress 记 console，路径归因当前页。
  /// G-B5：优先 Page.setDownloadBehavior（作用域收敛到当前页，新 tab 经
  /// Browser 级兜底不丢），失败回落 Browser.setDownloadBehavior（老内核
  /// 无 Page 域实现）；目录记入 _downloadDir，下载完成事件据此拼绝对路径。

BrowserRouteRule? matchRouteForTest(
    List<BrowserRouteRule> rules,
    String url,
  ) =>
      _matchRoute(rules, url);


BrowserRouteRule? _matchRoute(List<BrowserRouteRule> rules, String url) {
    for (final r in rules) {
      if (r.matches(url)) return r;
    }
    return null;
  }


  /// B6 决策纯函数（测试可见）：命中规则 → {method, params}；未命中 →
  /// {method: 'Fetch.continueRequest'}。

Map<String, dynamic> routeDecisionForTest(
    List<BrowserRouteRule> rules,
    Map<String, dynamic> request,
  ) {
    final url = '${request['url'] ?? ''}';
    final requestId = '${request['requestId'] ?? ''}';
    final rule = _matchRoute(rules, url);
    if (rule == null) {
      return {'method': 'Fetch.continueRequest', 'params': {'requestId': requestId}};
    }
    switch (rule.action) {
      case 'abort':
        return {
          'method': 'Fetch.failRequest',
          'params': {
            'requestId': requestId,
            'errorReason': rule.errorReason ?? 'Failed',
          },
        };
      case 'fulfill':
        return {
          'method': 'Fetch.fulfillRequest',
          'params': {
            'requestId': requestId,
            'responseCode': rule.fulfillStatus ?? 200,
            if (rule.fulfillHeaders.isNotEmpty)
              'responseHeaders': [
                for (final e in rule.fulfillHeaders.entries)
                  {'name': e.key, 'value': e.value},
              ],
            // G-B7：bodyBase64 优先（二进制 mock 原样透传）；plain body
            // 保持旧口径直传（既有 mock 行为不变）。
            if (rule.fulfillBodyBase64 != null)
              'body': rule.fulfillBodyBase64!
            else if (rule.fulfillBody != null) 'body': rule.fulfillBody!,
          },
        };
      case 'headers':
        final headers = <Map<String, dynamic>>[];
        for (final e in rule.fulfillHeaders.entries) {
          headers.add({'name': e.key, 'value': e.value});
        }
        return {
          'method': 'Fetch.continueRequest',
          'params': {
            'requestId': requestId,
            if (headers.isNotEmpty) 'headers': headers,
          },
        };
      default:
        return {
          'method': 'Fetch.continueRequest',
          'params': {'requestId': requestId},
        };
    }
  }


  /// R3-12：交互补齐——drag/select/upload/pressKey/scroll/hover/dialogAccept。
  /// B11：HTML5 拖放 dataTransfer 数据项（可选）——{types:[..], data:{"type":"值"}}。
  /// 页面 dragover 常读 event.dataTransfer.types/files 或 drop 读
  /// getData() 才放行 drop；无 data 的合成拖拽会被业务侧拒绝。

Map<String, dynamic>? dragDataTransferEnvelopeForTest(
    Map<String, dynamic>? raw,
  ) {
    if (raw == null) return null;
    final types = <String>[];
    final data = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      types.add(key);
      data[key] = '${entry.value}';
    }
    if (types.isEmpty) return null;
    return <String, dynamic>{'types': types, 'data': data};
  }


  /// R3-B4：payload 统一 base64 通道——此前手拼 `JSON.parse('$esc')` 只转义
  /// \ 和 '，U+2028/2029/未配对代理字符直接断 JS 字符串。与
  /// CdpClient.waitForSelector 同口径：b64 只含 [A-Za-z0-9+/=]，
  /// 注入单引号 JS 字符串绝对安全。返回解码表达式前缀，
  /// 调用方续写函数体（a 为已解析对象）。

String jsPayloadPrefixForTest(Map<String, String> payload) =>
      _jsPayloadPrefixFromJson(jsonEncode(payload));


  /// 工作区根：upload/download 落盘类操作 zone 门禁（R3-B7/R5-A4 同口径）。
  /// 为空时跳过本层门禁（单测直调兼容），与 AgentBrowserTools.rootPath 分层：
  /// 工具层已知 root 时会设置；service 层直调拼 CLI 时默认无 root 不拦截。

String? uploadRecheckForTest({
    required String filePath,
    required String? workspaceRoot,
    required bool exists,
    required bool isLink,
    required bool inside,
  }) {
    final p = filePath.trim();
    if (p.isEmpty) return '文件路径不能为空';
    if (!exists) return '上传文件不存在：$filePath';
    if (isLink) return '上传文件命中符号链接，已拒绝：$filePath';
    if (workspaceRoot != null &&
        workspaceRoot.isNotEmpty &&
        !inside) {
      return '上传文件命中工作区外/敏感路径，已拒绝：$filePath';
    }
    return null;
  }


  /// R3-B6：常用键码表——pressKey 此前只发 key 名，Enter/Tab/Escape/方向键
  /// Chrome 不认裸 key（无 code/windowsVirtualKeyCode/text），无效果或误触发。
  /// 补齐 code/vKey/text 三件套（与 selectAll/backspace 信封同口径）；
  /// 未收录键回退 key 名原口径。

Map<String, dynamic> pressKeyEnvelopeForTest(
    String type,
    String key,
    int modifiers,
  ) {
    final norm = key.trim().toLowerCase();
    final known = BrowserService._pressKeyCodes[norm];
    final env = <String, dynamic>{
      'type': type,
      'key': key,
      'modifiers': modifiers,
    };
    if (known != null) {
      env['code'] = known['code'];
      env['windowsVirtualKeyCode'] = known['windowsVirtualKeyCode'];
      // 仅 keyDown 带 text（keyUp   text 重复输入/提交）。
      if (type == 'keyDown' && known['text'] != null) {
        env['text'] = known['text'];
      }
    } else if (key.length == 1) {
      // 单字符键：code/vKey/text 可从键名推导（与 selectAll 信封同源）。
      // D8：数字 0-9 映射 Digit0-9（实体键盘数字排 KeyboardEvent.code
      // 口径）——此前数字沿用 KeyX 推导得 Key1 这类失真键名，监听
      // e.code 的页面收到不存在于实体键盘的键名；windowsVirtualKeyCode
      // 用数字字符码点（'1'→49，同 VK_1），其余单字符保持 KeyX 逻辑。
      final upper = key.toUpperCase();
      final isDigit =
          key.codeUnitAt(0) >= 0x30 && key.codeUnitAt(0) <= 0x39;
      env['code'] = isDigit ? 'Digit$key' : 'Key$upper';
      env['windowsVirtualKeyCode'] = isDigit
          ? key.codeUnitAt(0)
          : upper.codeUnitAt(0);
      if (type == 'keyDown') env['text'] = key;
    }
    return env;
  }


  /// R7-05：frameTree解析纯函数（测试可见）——单frame/多frame/空树可测。

List<Map<String, String>> parseFrameTreeForTest(Object? tree) {
    final out = <Map<String, String>>[];
    void walk(Map m) {
      final f = m['frame'];
      if (f is Map) {
        out.add({'id': '${f['id'] ?? ''}', 'url': '${f['url'] ?? ''}'});
      }
      final kids = m['childFrames'];
      if (kids is List) {
        for (final k in kids) {
          if (k is Map) walk(Map<String, dynamic>.from(k));
        }
      }
    }

    if (tree is Map) walk(Map<String, dynamic>.from(tree));
    return out;
  }


  /// D1（测试可见）：quad（8 数四角 x1y1x2y2x3y3x4y4）中心点——四顶点
  /// 算术中心（Puppeteer clickablePoint 口径），CSS 变换后仍落绘制区域内；
  /// 非 8 数/含非数返回 null（调用方报数据非法）。

({double x, double y})? quadCenterForTest(List<dynamic>? quad) {
    if (quad == null || quad.length != 8) return null;
    var sx = 0.0;
    var sy = 0.0;
    for (var i = 0; i < 8; i++) {
      final v = quad[i];
      if (v is! num) return null;
      if (i.isEven) {
        sx += v.toDouble();
      } else {
        sy += v.toDouble();
      }
    }
    return (x: sx / 4, y: sy / 4);
  }


  /// D1（测试可见）：Input.dispatchMouseEvent 信封——press/release 为
  /// left+clickCount=1；mouseMoved 用于 press 前悬停归位（button=none、
  /// clickCount=0，R6-2 口径）。

Map<String, dynamic> mouseClickEnvelopeForTest(
    String type,
    double x,
    double y,
  ) => {
    'type': type,
    'x': x,
    'y': y,
    'button': type == 'mouseMoved' ? 'none' : 'left',
    'clickCount': type == 'mouseMoved' ? 0 : 1,
  };


  /// D2（测试可见）：全选键信封——Ctrl/Meta+A，[modifier] 按平台
  /// （macOS meta=4，其余 ctrl=2，R15R8 口径）。

Map<String, dynamic> selectAllKeyEnvelopeForTest(
    String type,
    int modifier,
  ) => {
    'type': type,
    'modifiers': modifier,
    'key': 'a',
    'code': 'KeyA',
    'windowsVirtualKeyCode': 65,
  };


  /// D2（测试可见）：Backspace 键信封（windowsVirtualKeyCode 8）——
  /// 全选后删除选中内容，防旧值拼接而非替换。

Map<String, dynamic> backspaceKeyEnvelopeForTest(String type) => {
    'type': type,
    'key': 'Backspace',
    'code': 'Backspace',
    'windowsVirtualKeyCode': 8,
  };


  /// 输入：D2 Playwright fill 口径——click 聚焦（D1 原生 dispatchMouseEvent）
  /// → 全选（Input.dispatchKeyEvent Ctrl/Meta+A）→ Backspace 清空选中内容 →
  /// Input.insertText 整段插入（非逐键、非拼接，替换旧值）。特殊键盘操作全走
  /// Input.dispatchKeyEvent。来源 https://juejin.cn/post/7678988101557829638
  /// （playwright fill=focus+全选删除+insertText）与
  /// https://chromedevtools.github.io/devtools-protocol/tot/Input/。
  /// B4-02：文本走 CDP 参数不拼 JS，无引号逃逸；execCommand('insertText') 已废弃不用。
  /// 同 click：有副作用不重试，传输错仅 reset 后抛错。
  /// R8-2：可编辑性前置校验保留为只读 JS（不 focus 不滚动——聚焦改走原生
  /// 点击以获得真实 caret），非可编辑直接返回不 insertText 假成功。

String fillEditableJsForTest(String rawPayload) =>
      // R3-B4：payload 统一 b64 通道（见 jsPayloadPrefixForTest），
      // 参数为原始 JSON 串，不再要求调用方做引号转义。
      "${_jsPayloadPrefixFromJson(rawPayload)}"
      "const el=document.querySelector(a.s);if(!el) return 'no such element';"
      "const tag=(el.tagName||'').toUpperCase();"
      "const type=(el.type||'').toLowerCase();"
      "const editable=el.isContentEditable||tag==='TEXTAREA'||tag==='SELECT'||"
      "(tag==='INPUT'&&!['button','submit','reset','checkbox','radio','file','image','hidden'].includes(type));"
      "if(!editable) return 'not editable: '+tag+(type?'/'+type:'');"
      "if(el.disabled||el.readOnly||el.getAttribute('aria-disabled')==='true') return 'element not writable, skip fill';"
      "return 'editable '+el.tagName;}catch(e){return 'err';}})()";


String fillReadbackJsForTest(String rawPayload) =>
      "${_jsPayloadPrefixFromJson(rawPayload)}"
      "const el=document.querySelector(a.s);if(!el) return 'no such element';"
      "if(el.isContentEditable) return el.innerText||el.textContent||'';"
      "if('value' in el) return el.value==null?'':String(el.value);"
      "return el.textContent==null?'':String(el.textContent);}catch(e){return 'err';}})()";


  /// R3-B4：原始 JSON payload → b64 前缀（原始串即 JSON，无需转义）。

String _jsPayloadPrefixFromJson(String rawPayload) {
    final b64 = base64Encode(utf8.encode(rawPayload));
    return "(()=>{try{const bin=atob('$b64');"
        "const bytes=Uint8Array.from(bin,c=>c.charCodeAt(0));"
        "const json=(typeof TextDecoder!=='undefined'?new TextDecoder().decode(bytes):bin);"
        "const a=JSON.parse(json);";
  }
