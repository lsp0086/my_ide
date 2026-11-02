part of 'browser_service.dart';

  /// B13：逐字符输入（slowly）——按字符 dispatchKeyEvent（keyDown/char/keyUp）
  /// 触发页内 per-char input 监听。insertText 对只监听 key* 事件的输入框
  /// （自定义验证码/掩码输入）不触发 onChange，故提供慢口径。
  /// 序列：聚焦（同 fill）→ 全选+Backspace 清空 → 逐字符 →
  /// 回读比对（同 fill）。失败语义同 fill：任一步失败即抛错。

Map<String, dynamic> slowlyCharEnvelopeForTest(String phase, String ch) {
    // 单字符 key：多码位字符走 text 参数，Unicode 码点用 code。
    final runes = ch.runes.toList(growable: false);
    final code = runes.isEmpty ? 0 : runes.first;
    return {
      'type': phase,
      'key': ch,
      if (ch.length == 1) 'text': ch,
      'code': 'Key${code.toRadixString(16).toUpperCase()}',
      'unmodifiedText': ch,
    };
  }


  // ── B2-8：sensitive_data 占位符（browser-use 口径）──────────────────────
  // https://github.com/browser-use/browser-use ——密码等敏感值以 {{name}}
  // 占位符形态进模型上下文与工具参数，真实值仅在本层替换落地，工具输出/
  // 审计日志/对话历史不出现明文。与审批/围栏契合：占位符本身无秘密。

  /// B2-8 键规范化：允许 'pwd' 与 '{{pwd}}' 两种键形态（模型两种都会传），
  /// 统一去成对花括号后按 {{key}} 占位符口径替换/脱敏——此前只认裸键，
  /// 传 '{{pwd}}' 形态时 replaceAll('{{{pwd}}}') 永不命中，占位符原样
  /// 键入页面且回读比对必失败。

String normSensitiveKeyForTest(String key) {
    final t = key.trim();
    if (t.length >= 4 && t.startsWith('{{') && t.endsWith('}}')) {
      final inner = t.substring(2, t.length - 2).trim();
      if (inner.isNotEmpty) return inner;
    }
    return t;
  }


  /// B2-8 占位符替换纯函数（测试可见）：{{token}} → sensitive[token]。

String resolveSensitiveTokensForTest(
    String text,
    Map<String, String> sensitive,
  ) {
    if (sensitive.isEmpty) return text;
    var out = text;
    for (final e in sensitive.entries) {
      final key = normSensitiveKeyForTest(e.key);
      if (key.isEmpty) continue;
      out = out.replaceAll('{{$key}}', e.value);
    }
    return out;
  }


  /// B2-8 反向脱敏纯函数（测试可见）：文本中任何真实值出现即替换回
  /// {{token}} 占位符——成功路径本就不回显真实值，此处兜底错误路径
  /// （CDP 异常消息/回读比对文案可能夹带）不外泄明文。

String redactSensitiveForTest(
    String text,
    Map<String, String> sensitive,
  ) {
    if (sensitive.isEmpty) return text;
    var out = text;
    for (final e in sensitive.entries) {
      if (e.value.isEmpty) continue;
      out = out.replaceAll(e.value, '{{${normSensitiveKeyForTest(e.key)}}}');
    }
    return out;
  }


  /// 可交互快照 JS：DOM walker 为骨干 + ARIA 状态补充（B2-2）+ 穿透
  /// 同源 iframe / open shadow root（A3-7/B2-3）。
  /// - B2-2：每行输出 role / name（aria-label→alt→title→placeholder→value→
  ///   可见文本）/ type / checked / selected / disabled / required / readonly
  ///   / expanded，自绘组件（role=button 的 div）与表单状态可判定，
  ///   保留 flat-list 省 token 特性（参照 browser-use views.py 三源合并思路，
  ///   不引依赖：https://raw.githubusercontent.com/browser-use/browser-use/main/browser_use/dom/views.py）。
  /// - B2-3：主文档 → 同源 iframe contentDocument（递归）→ 每节点 open
  ///   shadowRoot 递归；非主文档行加 `(iframe#N)` frame 上下文前缀，
  ///   跨进程 OOPIF（contentDocument 读不到）单独标注 frame 指引行。
  /// - B2-1：返回串尾部以 NUL 分隔 DOM 签名（元素数+子节点数），Dart 侧
  ///   据此判 ref 是否 stale；签名不进入模型可见文本。

String _snapshotJs(int cap) =>
      '(function(n){const out=[];'
      'const skip=new Set(["SCRIPT","STYLE","NOSCRIPT","TEMPLATE","SVG","PATH"]);'
      'const ROLE={A:"link",BUTTON:"button",SELECT:"combobox",TEXTAREA:"textbox",'
      'IMG:"img",NAV:"navigation",HEADER:"banner",FOOTER:"contentinfo",MAIN:"main",'
      'ASIDE:"complementary",FORM:"form",TABLE:"table",UL:"list",OL:"list",'
      'LI:"listitem",H1:"heading",H2:"heading",H3:"heading",H4:"heading",'
      'H5:"heading",H6:"heading",SUMMARY:"button"};'
      'const IROLE={checkbox:"checkbox",radio:"radio",button:"button",'
      'submit:"button",reset:"button",range:"slider",number:"spinbutton",'
      'search:"searchbox",email:"textbox",text:"textbox",password:"textbox",'
      'tel:"textbox",url:"textbox"};'
      // B2-2：可访问名候选序（aria-label → alt → title → placeholder → value）
      'function accName(el,t){var v=null;'
      'try{v=el.getAttribute("aria-label");}catch(_){}'
      'if(v&&v.trim())return v.trim();'
      'try{v=el.getAttribute("alt");}catch(_){}'
      'if(v&&v.trim())return v.trim();'
      'try{v=el.getAttribute("title");}catch(_){}'
      'if(v&&v.trim())return v.trim();'
      'try{v=el.getAttribute("placeholder");}catch(_){}'
      'if(v&&v.trim())return v.trim();'
      'if(t==="INPUT"||t==="TEXTAREA"||t==="SELECT"){'
      'try{var ty=(el.type||"").toLowerCase();'
      'if(ty!=="password"&&el.value&&el.value.trim())return el.value.trim();}catch(_){}}'
      'return "";}'
      // B2-2：状态位——checked/selected/disabled/required/readonly/expanded
      'function stateOf(el,t){var f="";'
      'try{'
      'if(el.disabled===true||el.getAttribute("aria-disabled")==="true")f+=" disabled";'
      'if((t==="INPUT"&&(el.type==="checkbox"||el.type==="radio")&&el.checked)'
      '||el.getAttribute("aria-checked")==="true")f+=" checked";'
      'if(el.selected===true||el.getAttribute("aria-selected")==="true")f+=" selected";'
      'if(el.getAttribute("aria-expanded")==="true")f+=" expanded";'
      'if(el.required===true)f+=" required";'
      'if(el.readOnly===true)f+=" readonly";'
      '}catch(_){}return f;}'
      'function q(s){return String.fromCharCode(34)+s.replace(/"/g,String.fromCharCode(39)).slice(0,60)+String.fromCharCode(34);}'
      'var i=0;'
      // B2-3：逐文档 walker（主文档优先，同源 iframe 递归），shadow root 递归
      'function walk(doc,ft,isShadow){'
      'var body=isShadow?doc:(doc.body||doc.documentElement);if(!body)return;'
      'var w=doc.createTreeWalker(body,NodeFilter.SHOW_ELEMENT);let el;'
      'while((el=w.nextNode())&&out.length<n){'
      'const t=el.tagName;if(skip.has(t))continue;'
      'const st=getComputedStyle(el);if(st.display==="none"||st.visibility==="hidden")continue;'
      'const r=el.getBoundingClientRect();if(r.width<=0&&r.height<=0&&t!=="INPUT"&&t!=="BUTTON")continue;'
      'const interactive=/^(A|BUTTON|INPUT|SELECT|TEXTAREA)\$/.test(t)'
      '||el.hasAttribute("onclick")||el.getAttribute("role")==="button"'
      // B2-10：JS 监听元素识别——addEventListener 包装打的标记属性
      // （init script 在页面加载时注入）+ DIV/SPAN 的 cursor:pointer
      // 启发式（React 17+ 事件委托到根容器局面，标记不可达时兜底），
      // 框架事件驱动的 div 卡片据此标为可交互
      // （browser-use getEventListeners 思路的轻量版）。
      '||el.hasAttribute("data-ml-listener")'
      '||((t==="DIV"||t==="SPAN")&&(function(){try{'
      'return getComputedStyle(el).cursor==="pointer";}catch(_){return false;}})());'
      'const text=(el.innerText||el.textContent||"").trim().replace(/\\s+/g," ").slice(0,80);'
      'if(!interactive&&text.length<2)continue;'
      'i++;let sel=t.toLowerCase();if(el.id)sel+="#"+el.id;'
      // B2-2：role/type/name/state 四件套
      'const role=el.getAttribute("role")||ROLE[t]'
      '||(t==="INPUT"?IROLE[(el.type||"").toLowerCase()]:"")||t.toLowerCase();'
      'const tsuf=(t==="INPUT"&&el.type)?" input:"+el.type:"";'
      'const nm=accName(el,t);'
      'var head="e"+i+" ["+t.toLowerCase()+tsuf+"]";'
      'if(role&&role!==t.toLowerCase())head+=" role="+role;'
      'head+=nm?" name="+q(nm):(text?" name="+q(text):"");'
      'head+=stateOf(el,t);'
      'out.push(head+" :: "+sel);'
      'if(ft)out[out.length-1]=ft+out[out.length-1];'
      'var sr=null;try{sr=el.shadowRoot;}catch(_){}'
      'if(sr&&sr.mode==="open")walk(sr,ft,true);}}'
      // B2-3：iframe 递归 + 跨进程 OOPIF 指引行
      'function frames(doc,fi){var frs=[];try{frs=doc.querySelectorAll("iframe,frame");}catch(_){}'
      'for(var k=0;k<frs.length;k++){var d=null;try{d=frs[k].contentDocument;}catch(_){}'
      'var ft="(iframe#"+(fi+k+1)+")";'
      'if(d){if(out.length<n){var u="";try{u=d.location?d.location.href:"";}catch(_){}}'
      'if(out.length<n)out.push(ft+(u?" "+u:"")+" 子文档已穿透");'
      'walk(d,ft);frames(d,fi+k+1);}'
      'else if(out.length<n){var src="";try{src=frs[k].getAttribute("src")||frs[k].src||"";}catch(_){}'
      'out.push(ft+"! 跨进程 iframe 不可穿透"+(src?"（"+src+"）":"")'
      // C6 口径对齐：跨进程（OOPIF）子会话上下文不入 eval 存活表，
      // browser_eval(contextId) 只覆盖主会话上下文，此处不再误导性指向
      // browser_frames→browser_eval(contextId) 链（frameId≠contextId 且
      // 跨进程上下文不可达），改指 browser_open 直开该 URL 读写。
      '+"：请 browser_open 直开该 URL 读写，'
      'DOM 点击/输入工具无法直达");}}}'
      'walk(document,"",false);frames(document,0);'
      // B2-1：DOM 签名（NUL 分隔，不进模型可见文本）
      'var sig=(document.getElementsByTagName("*").length)+":"'
      '+(document.body?document.body.childElementCount:0)+":"'
      '+(document.documentElement?document.documentElement.childElementCount:0);'
      'return (out.length?out.join("\\n"):"(空快照)")+"\\u0000"+sig;})($cap)';


  /// evaluate 返回解包：{result:{result:{value}}} 双层或 {result:{value}} 均解为字符串。
  /// 测试钩子：单测断言快照 JS 口径与解包，避免私有方法不可测。

String snapshotJsForTest(int cap) => _snapshotJs(cap);


  /// B2-10：JS 监听标记 init script（测试可见）——包装 Element.prototype
  /// .addEventListener，给绑定过监听器的元素打 data-ml-listener 属性；
  /// 快照 interactive 判定（_snapshotJs）据此把框架事件驱动的元素标为
  /// 可交互。经 Page.addScriptToEvaluateOnNewDocument 随建连注册，仅对新
  /// 文档生效；React 17+ 委托到根容器的场景由 cursor:pointer 启发式兜底。

String listenerTagScriptForTest() => r'''
(function(){try{
var orig=Element.prototype.addEventListener;
Element.prototype.addEventListener=function(type,fn,opt){
  try{this.setAttribute('data-ml-listener','1');}catch(_){}
  return orig.call(this,type,fn,opt);
};}catch(_){}})();
''';


  /// GB1（测试可见）：initScript 注入信封——按 B2-10 listener 标记脚本同模式
  /// 扩展：IIFE 包裹隔离用户脚本词法作用域（内部 var 不泄漏 window），
  /// Object.defineProperty 定义不可写/不可配置的 window.__agentInitScript
  /// 标记（防页面侧覆盖/探测注入状态），整体 try/catch 尽力而为不阻断导航。
  /// 经 Page.addScriptToEvaluateOnNewDocument 注册即跨导航存活（每个新文档
  /// 执行一次）。

String initScriptEnvelopeForTest(String script) =>
      '(function(){try{'
      "if(!('__agentInitScript' in window)){"
      "Object.defineProperty(window,'__agentInitScript',"
      '{value:true,writable:false,enumerable:false,configurable:false});}'
      '(function(){\n$script\n})();'
      '}catch(_){}})();';


  /// GB1（测试可见）：draggable 探测 JS（drag 结构化路径判定）——
  /// src 元素 draggable 属性为 true 返回 '1'，否则 '0'（命中失败也回 '0'
  /// 走鼠标合成兜底）。b64 通道传参（与 fill/select 同口径防注入）。

String draggableProbeJsForTest(String selector) =>
      '${jsPayloadPrefixForTest({'s': selector})}'
      "${CdpClient.pierceHelperJs}"
      "var el=null;try{el=__pierceQuery(a.s);}catch(_){}"
      "if(!el){try{el=document.querySelector(a.s);}catch(_){}}"
      "if(!el) return '0';"
      "try{if(el.draggable===true||"
      "el.getAttribute('draggable')==='true') return '1';}catch(_){}"
      "return '0';}catch(e){return '0';}})()";


  /// GB5（测试可见）：Input.dispatchDragEvent 结构化 DragData 信封——
  /// CDP DragData {items: [DragDataItem{mimeType,data}], dragOperationsMask}。
  /// dataTransfer 数据项（{"MIME": "值"}）逐项进 items；无数据时保底一条
  /// 空 text/plain（CDP items 为必填数组）。dragOperationsMask 恒 1（copy，
  /// Chrome 默认放行语义）。

Map<String, dynamic> dragDataEnvelopeForTest(
    Map<String, dynamic>? dt,
  ) {
    final items = <Map<String, dynamic>>[];
    if (dt != null) {
      for (final entry in dt.entries) {
        final k = entry.key.trim();
        if (k.isEmpty) continue;
        items.add({'mimeType': k, 'data': '${entry.value}'});
      }
    }
    if (items.isEmpty) {
      items.add(const {'mimeType': 'text/plain', 'data': ''});
    }
    return {'items': items, 'dragOperationsMask': 1};
  }


String unwrapForTest(Map<String, dynamic> r) =>
      _unwrapEvaluateValue(r);


  // ── B2-1：快照元素引用回链（ref eN → selector）─────────────────────────

  /// 快照 ref 表：ref → selector，附快照时 DOM 签名与 URL。
  /// 交互工具（click/fill/hover/select/scroll/upload/drag）收 ref 即查此表，
  /// 命中走与原 selector 完全一致的链路（向后兼容）；DOM 签名变化即判 stale。

({String text, String sig}) splitSnapshotSigForTest(String raw) =>
      _splitSnapshotSig(raw);


({String text, String sig}) _splitSnapshotSig(String raw) {
    final idx = raw.indexOf('\u0000');
    if (idx < 0) return (text: raw, sig: '');
    return (text: raw.substring(0, idx), sig: raw.substring(idx + 1));
  }


  /// 从快照文本重建 ref 表（eN → selector）：行首 ref 与行尾 ` :: selector`。
  /// 同一快照内 eN 唯一（JS 侧 i 单调自增），重复 ref 后者不覆盖前者。

Map<String, String> parseSnapshotRefsForTest(String text) =>
      _parseSnapshotRefs(text);


Map<String, String> _parseSnapshotRefs(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final m = RegExp(r'(?:^|\s)(e\d+)\s').firstMatch(t);
      if (m == null) continue;
      final sep = t.lastIndexOf(' :: ');
      if (sep < 0) continue;
      final sel = t.substring(sep + 4).trim();
      if (sel.isEmpty) continue;
      out.putIfAbsent(m.group(1)!, () => sel);
    }
    return out;
  }


  /// B2-1 stale 判定纯函数（测试可见）：签名任一为空或两者不等即 stale
  /// （空签名=快照侧未取到/嵌入通道假快照，保守判 stale 不用含糊的
  /// "元素未出现"混报）。

bool refStaleForTest(String snapSig, String nowSig) {
    if (snapSig.isEmpty || nowSig.isEmpty) return true;
    return snapSig != nowSig;
  }


  /// DOM 签名 JS（B2-1 stale 判定）：与 _snapshotJs 尾部签名同口径，
  /// 单次轻量 evaluate（元素数+子节点数），不拉整页 body。

String domSigJsForTest() =>
      '(function(){var d=document;'
      'return (d.getElementsByTagName("*").length)+":"'
      '+(d.body?d.body.childElementCount:0)+":"'
      '+(d.documentElement?d.documentElement.childElementCount:0);})()';


  // ── B2-4：快照 find（文本/regex 子树）与 boxes（bbox）────────────────────

  /// B2-4 find：按文本/regex 在穿透域（主文档+同源 iframe+open shadow）
  /// 匹配元素，返回「路径上下文 > 命中元素」行集（不超过 maxLines）。
  /// payload {q, re}：re=true 时 q 按正则（编译失败退回子串）。

String snapshotFindJsForTest(Map<String, dynamic> payload) {
    final b64 = base64Encode(
      utf8.encode(jsonEncode({'q': '${payload['q']}', 're': payload['re'] == true})),
    );
    return '${CdpClient.pierceHelperJs}'
        "(()=>{try{const bin=atob('$b64');"
        'const bytes=Uint8Array.from(bin,c=>c.charCodeAt(0));'
        "const json=(typeof TextDecoder!=='undefined'?new TextDecoder().decode(bytes):bin);"
        'const a=JSON.parse(json);'
        'var re=null;if(a.re){try{re=new RegExp(a.q,"i");}catch(_){re=null;}}'
        'function hit(t){if(!t)return false;'
        'if(re)return re.test(t);return t.toLowerCase().indexOf(a.q.toLowerCase())>=0;}'
        'function pathOf(el){var s=[];var n=el;while(n&&s.length<8){'
        'var tn=n.tagName?n.tagName.toLowerCase():(n.nodeName||"?").toLowerCase();'
        'var id="";try{id=n.id?"#"+n.id:"";}catch(_){}'
        's.unshift(tn+id);n=n.parentElement||n.parentNode;}return s.join("<");}'
        'var out=[];'
        '__pierceEach(function(e){if(out.length>=200)return false;'
        'var t=(e.innerText||e.textContent||"").trim().replace(/\\s+/g," ");'
        'if(t.length<1)return;'
        'if(!hit(t))return;'
        'var short=t.slice(0,80);'
        'out.push(pathOf(e)+" :: "+short);});'
        'return out.join("\\n")||"(未命中)";}catch(e){return "err:"+e;}})()';
  }


  /// B2-4 boxes：穿透域内匹配 selector 的全部元素 bbox（JSON 数组，
  /// x/y/width/height 与 getBoundingClientRect 完全一致——容差 0）。

String elementBoxesJsForTest(String selector) {
    final b64 = base64Encode(utf8.encode(jsonEncode({'s': selector})));
    return '${CdpClient.pierceHelperJs}'
        "(()=>{try{const bin=atob('$b64');"
        'const bytes=Uint8Array.from(bin,c=>c.charCodeAt(0));'
        "const json=(typeof TextDecoder!=='undefined'?new TextDecoder().decode(bytes):bin);"
        'const a=JSON.parse(json);var out=[];'
        'var roots=__pierceRootsOfDoc();'
        'for(var ri=0;ri<roots.length;ri++){var arr=[];'
        'try{arr=roots[ri].querySelectorAll(a.s);}catch(_){}'
        'for(var k=0;k<arr.length;k++){var r=arr[k].getBoundingClientRect();'
        'out.push({x:r.x,y:r.y,width:r.width,height:r.height});}}'
        'return JSON.stringify(out);}catch(e){return "err:"+e;}})()';
  }


  /// B2-4 boxes 解析纯函数（测试可见）：JS 返回的 JSON 串 → 结构化列表。
  /// 与 getBoundingClientRect 逐字段相等（容差 1px 由调用方比对）。

List<Map<String, double>> parseBoxesForTest(String raw) {
    final t = raw.trim();
    if (t.startsWith('err:')) {
      throw StateError('取元素坐标失败：${t.substring(4)}');
    }
    final decoded = jsonDecode(t);
    if (decoded is! List) return const [];
    final out = <Map<String, double>>[];
    for (final e in decoded) {
      if (e is! Map) continue;
      out.add({
        'x': ((e['x'] as num?)?.toDouble() ?? 0),
        'y': ((e['y'] as num?)?.toDouble() ?? 0),
        'width': ((e['width'] as num?)?.toDouble() ?? 0),
        'height': ((e['height'] as num?)?.toDouble() ?? 0),
      });
    }
    return out;
  }


  /// B2-4 测试钩子：两个 bbox 是否在 1px 容差内相等（校验标准：容差1px）。

bool boxesEqualForTest(Map<String, dynamic> a, Map<String, dynamic> b) {
    double d(String k) => ((a[k] as num?)?.toDouble() ?? double.nan);
    double e(String k) => ((b[k] as num?)?.toDouble() ?? double.nan);
    for (final k in const ['x', 'y', 'width', 'height']) {
      if ((d(k) - e(k)).abs() > 1) return false;
    }
    return true;
  }


  // ── GB3：DOMSnapshot.captureSnapshot 扁平表（boxes/find 快速路径）───────

  /// GB3：captureSnapshot 响应 → 扁平节点表。domNodes 全局单表（跨域 iframe
  /// 经 contentDocument 内联、shadow 根内节点平铺，均为树形 childNodeIndexes），
  /// layoutTreeNodes 经 domNodeIndex→layoutNodeIndex 关联 boundingBox
  /// （includeDOMRects:true 时返回，CSS 像素坐标，与 getBoundingClientRect
  /// 同源）。解析失败（响应畸形）返回 null，调用方回退 evaluate 路径。

({
    List<Map<String, dynamic>> nodes,
    Map<int, int> parents,
    Map<int, Map<String, double>> bbox,
  })? _domSnapshotTable(Map<String, dynamic> snapshot) {
    try {
      final rawNodes = snapshot['domNodes'];
      if (rawNodes is! List) return null;
      final nodes = <Map<String, dynamic>>[];
      final parents = <int, int>{};
      for (var i = 0; i < rawNodes.length; i++) {
        final n = rawNodes[i];
        nodes.add(n is Map ? Map<String, dynamic>.from(n) : const {});
        if (n is Map) {
          final kids = n['childNodeIndexes'];
          if (kids is List) {
            for (final c in kids) {
              if (c is num) parents[c.toInt()] = i;
            }
          }
        }
      }
      final bbox = <int, Map<String, double>>{};
      final rawLayouts = snapshot['layoutTreeNodes'];
      if (rawLayouts is List) {
        for (final l in rawLayouts) {
          if (l is! Map) continue;
          final di = (l['domNodeIndex'] as num?)?.toInt();
          final bb = l['boundingBox'];
          if (di == null || bb is! Map) continue;
          bbox[di] = {
            'x': (bb['x'] as num?)?.toDouble() ?? 0,
            'y': (bb['y'] as num?)?.toDouble() ?? 0,
            'width': (bb['width'] as num?)?.toDouble() ?? 0,
            'height': (bb['height'] as num?)?.toDouble() ?? 0,
          };
        }
      }
      return (nodes: nodes, parents: parents, bbox: bbox);
    } catch (_) {
      return null;
    }
  }


  /// GB3：domNode 的 attributes 归一（ToT 为 {name: value} Map；部分实现为
  /// 扁平 [name, value, …] 偶对数组），键名小写。

Map<String, String> _domSnapshotAttributes(Map<String, dynamic> node) {
    final a = node['attributes'];
    final out = <String, String>{};
    if (a is Map) {
      a.forEach((k, v) => out['$k'.toLowerCase()] = '$v');
    } else if (a is List) {
      for (var i = 0; i + 1 < a.length; i += 2) {
        out['${a[i]}'.toLowerCase()] = '${a[i + 1]}';
      }
    }
    return out;
  }


  /// GB3：扁平表可判定的简单选择器谓词。支持 tag、#id、.class、[attr]、
  /// [attr=v]（含引号）及单复合组合（div#a.b[c=d]）；含空格/逗号/关系符/
  /// 伪类即 null（调用方回退 evaluate 穿透路径，语义不回归）。

bool Function(String nodeName, Map<String, String> attrs)?
  _simpleSelectorMatcher(String selector) {
    final s = selector.trim();
    if (s.isEmpty || s.contains(RegExp(r'[\s,>+~]'))) return null;
    var rest = s;
    String? tag;
    var id = '';
    final classes = <String>{};
    final attrPreds = <bool Function(Map<String, String> attrs)>[];
    final tagM = RegExp(r'^[A-Za-z][A-Za-z0-9-]*').firstMatch(rest);
    if (tagM != null) {
      tag = tagM.group(0)!.toLowerCase();
      rest = rest.substring(tagM.end);
    }
    while (rest.isNotEmpty) {
      if (rest.startsWith('#')) {
        final m = RegExp(r'^#([A-Za-z0-9_-]+)').firstMatch(rest);
        if (m == null) return null;
        id = m.group(1)!;
        rest = rest.substring(m.end);
      } else if (rest.startsWith('.')) {
        final m = RegExp(r'^\.([A-Za-z0-9_-]+)').firstMatch(rest);
        if (m == null) return null;
        classes.add(m.group(1)!);
        rest = rest.substring(m.end);
      } else if (rest.startsWith('[')) {
        final close = rest.indexOf(']');
        if (close < 0) return null;
        final inner = rest.substring(1, close).trim();
        rest = rest.substring(close + 1);
        final eq = inner.indexOf('=');
        if (eq < 0) {
          final name = inner.toLowerCase();
          attrPreds.add((a) => a.containsKey(name));
        } else {
          final name = inner.substring(0, eq).trim().toLowerCase();
          var value = inner.substring(eq + 1).trim();
          if (value.length >= 2 &&
              ((value.startsWith('"') && value.endsWith('"')) ||
                  (value.startsWith("'") && value.endsWith("'")))) {
            value = value.substring(1, value.length - 1);
          }
          attrPreds.add((a) => a[name] == value);
        }
      } else {
        // 伪类/结构伪元素等扁平表判定不了的形态。
        return null;
      }
    }
    return (nodeName, attrs) {
      if (tag != null && nodeName.toLowerCase() != tag) return false;
      if (id.isNotEmpty && (attrs['id'] ?? '') != id) return false;
      if (classes.isNotEmpty) {
        final cls = (attrs['class'] ?? '')
            .split(RegExp(r'\s+'))
            .where((c) => c.isNotEmpty)
            .toSet();
        if (!classes.every(cls.contains)) return false;
      }
      for (final p in attrPreds) {
        if (!p(attrs)) return false;
      }
      return true;
    };
  }


  /// GB3（测试可见）：captureSnapshot 扁平表 + 选择器 → bbox 列表（文档序）。
  /// 与 getBoundingClientRect 逐字段一致（同源布局坐标，容差 0）；无布局
  /// 盒的节点（display:none 等不产生 layout 节点）跳过。选择器超扁平表判定
  /// 能力（伪类/关系符等）返回 null，调用方回退 evaluate 路径。

List<Map<String, double>>? domSnapshotBoxesForTest(
    Map<String, dynamic> snapshot,
    String selector,
  ) {
    final table = _domSnapshotTable(snapshot);
    if (table == null) return null;
    final pred = _simpleSelectorMatcher(selector);
    if (pred == null) return null;
    final out = <Map<String, double>>[];
    for (var i = 0; i < table.nodes.length; i++) {
      final n = table.nodes[i];
      if ((n['nodeType'] as num?)?.toInt() != 1) continue;
      if (!pred('${n['nodeName'] ?? ''}', _domSnapshotAttributes(n))) continue;
      final bb = table.bbox[i];
      if (bb == null) continue;
      out.add(bb);
    }
    return out;
  }


  /// GB3（测试可见）：captureSnapshot 扁平表 + 文本/regex 匹配 → find 行集。
  /// 与 evaluate 路径同形：「path :: 文本」行（路径 tag#id<… 最多 8 级、文本
  /// 空白归一后取前 80 字符），文档序，上限 200 行。匹配面：元素聚合后代
  /// 文本节点 + 输入值（inputValue），含跨域 iframe 与扁平 shadow。

List<String> domSnapshotFindForTest(
    Map<String, dynamic> snapshot,
    String query, {
    bool regex = false,
  }) {
    final table = _domSnapshotTable(snapshot);
    if (table == null) return const [];
    RegExp? re;
    if (regex) {
      try {
        re = RegExp(query, caseSensitive: false);
      } catch (_) {
        re = null; // 编译失败退回子串（与 evaluate 路径同口径）。
      }
    }
    final q = query.toLowerCase();
    bool hit(String text) {
      if (re != null) return re.hasMatch(text);
      return text.toLowerCase().contains(q);
    }

    final kidsOf = <int, List<int>>{};
    table.parents.forEach((child, parent) {
      kidsOf.putIfAbsent(parent, () => []).add(child);
    });
    final memo = <int, String>{};
    // 规则1自检：畸形快照父子成环时 textOf 深递归可栈溢出——DFS 重入
    // （同节点未算完又被递归访问）即判定环，返回空串断开，聚合文本有损
    // 但不崩；正常树形重入不发生，零额外成本。
    final inProgress = <int>{};
    String textOf(int idx) {
      final cached = memo[idx];
      if (cached != null) return cached;
      if (!inProgress.add(idx)) return '';
      final n = table.nodes[idx];
      final type = (n['nodeType'] as num?)?.toInt() ?? 0;
      var s = '';
      if (type == 3) {
        s = '${n['nodeValue'] ?? ''}';
      } else if (type == 1) {
        final buf = StringBuffer();
        final iv = '${n['inputValue'] ?? ''}';
        if (iv.isNotEmpty) buf.write(iv);
        for (final c in kidsOf[idx] ?? const <int>[]) {
          final ct = textOf(c);
          if (ct.isNotEmpty) buf.write(' $ct');
        }
        s = buf.toString();
      }
      inProgress.remove(idx);
      memo[idx] = s;
      return s;
    }

    String pathOf(int idx) {
      final parts = <String>[];
      var cur = idx;
      while (cur >= 0 && parts.length < 8) {
        final node = table.nodes[cur];
        if ((node['nodeType'] as num?)?.toInt() == 1) {
          var tn = '${node['nodeName'] ?? '?'}'.toLowerCase();
          final id = _domSnapshotAttributes(node)['id'] ?? '';
          if (id.isNotEmpty) tn = '$tn#$id';
          parts.insert(0, tn);
        }
        cur = table.parents[cur] ?? -1;
      }
      return parts.isEmpty ? '?' : parts.join('<');
    }

    final out = <String>[];
    for (var i = 0; i < table.nodes.length; i++) {
      if (out.length >= 200) break;
      final n = table.nodes[i];
      if ((n['nodeType'] as num?)?.toInt() != 1) continue;
      final text = textOf(i).trim().replaceAll(RegExp(r'\s+'), ' ');
      if (text.isEmpty) continue;
      if (!hit(text)) continue;
      out.add('${pathOf(i)} :: ${text.length > 80 ? text.substring(0, 80) : text}');
    }
    return out;
  }
