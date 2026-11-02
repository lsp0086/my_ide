part of 'chrome_cdp.dart';

/// 等待与内容读取：outerHTML、pierce 穿透 JS 辅助、waitForSelector 轮询。

/// R17-D1 DOM 穿透 JS 辅助（iframe contentDocument 扫描 + open shadow root
/// 递归，主文档优先）：waitForSelector（A3-2）/遮挡检查（A3-1）/快照
/// （A3-7/B2-3）三处同源复用，单一实现防口径分裂。
/// - __pierceRootsOfDoc：主文档 + 同源 iframe/frame contentDocument（递归；
///   cross-origin OOPIF 访问 contentDocument 抛错即跳过，保持既有文档化行为，
///   由 DOM pierce 查询兜底，报错文案给 frameId/url 指引）。
/// - __pierceWalkOpen：TreeWalker 遍历 + 每节点 open shadowRoot 递归
///   （TreeWalker 本身不穿透 shadow 边界，shadow DOM 元素永不出现在
///   主文档树遍历结果里）。
/// - __pierceQueryInfo：按 roots 顺序 querySelector（主文档优先，命中即返；
///  同文档内 document.querySelector 已默认穿透 open shadow root，此处
///  对 shadow root 再做一次显式 recursiv 兜底）。返回 {el, doc} 附带宿主
///  文档，供遮挡检查/快照标注 frame 上下文（A3-1/B2-3）。
/// - __pierceText：同源 iframe textContent 拼接（waitFor 文本口径 A3-15）。
/// - __pierceAtPoint：elementFromPoint 归属判定——命中 IFRAME/FRAME 宿主时
///  按 boundingClientRect 偏移下钻 contentDocument（A3-1：iframe 内元素
///  elementFromPoint 返回 IFRAME 宿主致误判 covered 的修复）。
/// - __pierceLocate：B2-5 定位兜底链求值（CSS → role= → text= → xpath），
///  命中返回 {el, doc, via}；via 注明命中路径，供动作输出展示。
/// 全部用 function 声明（非 const/let）：同一上下文重复 evaluate 重复
/// 声明不抛错，避免常量重声明语法错误。
const _pierceHelperJs = r'''
function __pierceRoots(doc,out){out.push(doc);
try{var frs=doc.querySelectorAll('iframe,frame');
for(var i=0;i<frs.length;i++){try{var d=frs[i].contentDocument;if(!d)continue;
var dup=false;for(var j=0;j<out.length;j++){if(out[j]===d){dup=true;break;}}
if(!dup)__pierceRoots(d,out);}catch(_){}}}catch(_){}}
function __pierceRootsOfDoc(){var out=[];__pierceRoots(document,out);return out;}
function __pierceWalkOpen(root,doc,seen,visit){
var w=null;try{w=doc.createTreeWalker(root,NodeFilter.SHOW_ELEMENT);}catch(_){return true;}
var el;while((el=w.nextNode())){if(visit(el,doc)===false)return false;
var sr=null;try{sr=el.shadowRoot;}catch(_){}
if(sr&&sr.mode==='open'&&seen.indexOf(sr)<0){seen.push(sr);
if(__pierceWalkOpen(sr,doc,seen,visit)===false)return false;}}
return true;}
function __pierceEach(visit){var roots=__pierceRootsOfDoc();
for(var i=0;i<roots.length;i++){var doc=roots[i];
if(__pierceWalkOpen(doc.body||doc.documentElement,doc,[],visit)===false)return;}}
function __pierceQuery(sel){var roots=__pierceRootsOfDoc();
for(var i=0;i<roots.length;i++){var found=null;
try{found=roots[i].querySelector(sel);}catch(_){}
if(found)return found;
try{var hosts=roots[i].querySelectorAll('*');
for(var k=0;k<hosts.length;k++){var sr=hosts[k].shadowRoot;if(!sr)continue;
var inner=null;try{inner=sr.querySelector(sel);}catch(_){}
if(inner)return inner;}}catch(_){}}
return null;}
function __pierceQueryInfo(sel){var roots=__pierceRootsOfDoc();
for(var i=0;i<roots.length;i++){var found=null;
try{found=roots[i].querySelector(sel);}catch(_){}
if(found)return {el:found,doc:roots[i]};
try{var hosts=roots[i].querySelectorAll('*');
for(var k=0;k<hosts.length;k++){var sr=hosts[k].shadowRoot;if(!sr)continue;
var inner=null;try{inner=sr.querySelector(sel);}catch(_){}
if(inner)return {el:inner,doc:roots[i]};}}catch(_){}}
return null;}
function __pierceText(){var t='';var roots=__pierceRootsOfDoc();
for(var i=0;i<roots.length;i++){try{t+=(roots[i].body?roots[i].body.textContent:'')||'';}catch(_){}}
return t;}
function __pierceAtPoint(x,y){var doc=document;
for(var depth=0;depth<4;depth++){var hit=null;try{hit=doc.elementFromPoint(x,y);}catch(_){}
if(!hit)return null;
var tn=hit.tagName||'';
if(tn==='IFRAME'||tn==='FRAME'){var d=null;try{d=hit.contentDocument;}catch(_){}
if(d){try{var r=hit.getBoundingClientRect();x=x-r.left;y=y-r.top;}catch(_){}
doc=d;continue;}}
return {el:hit,doc:doc};}
return null;}
function __pierceVisible(el){if(!el) return false;
try{var r=el.getBoundingClientRect();var st=getComputedStyle(el);
return r.width>0&&r.height>0&&st.visibility!=='hidden'&&st.display!=='none';}catch(_){return false;}}
function __pierceRoleName(el,role,want){var r=el.getAttribute?el.getAttribute('role'):'';
var nm='';try{nm=el.getAttribute('aria-label')||'';}catch(_){}
return (r||'')===role&&nm.indexOf(want)>=0;}
function __pierceLocate(spec){var s0=(spec||'').trim();if(!s0)return null;
var res=null;
if(s0.indexOf('role=')===0){var body=s0.slice(5);var ci=body.indexOf(':');
var role=ci<0?body:body.slice(0,ci);var want=ci<0?'':body.slice(ci+1);
__pierceEach(function(e){if(res)return false;
if(__pierceRoleName(e,role,want)){res={el:e,via:'role='+(ci<0?role:role+':'+want)};return false;}});
return res;}
if(s0.indexOf('text=')===0){var want2=s0.slice(5).toLowerCase();
__pierceEach(function(e){if(res)return false;
var t=(e.innerText||e.textContent||'').toLowerCase();
if(t.indexOf(want2)>=0&&__pierceVisible(e)){res={el:e,via:'text='+want2};return false;}});
return res;}
if(s0.indexOf('//')===0||s0.indexOf('(//')===0){var roots=__pierceRootsOfDoc();
for(var ri=0;ri<roots.length&&!res;ri++){
try{var it=roots[ri].evaluate(s0,roots[ri],null,XPathResult.FIRST_ORDERED_NODE_TYPE,null);
if(it&&it.singleNodeValue)res={el:it.singleNodeValue,doc:roots[ri],via:'xpath='+s0};}catch(_){}}}
return res;}
''';

extension CdpClientWait on CdpClient {
  /// 取渲染后 HTML：走 Runtime.evaluate 拿 outerHTML，比 DOM.getDocument 省包。
  Future<String> outerHtml({int maxChars = 20000}) async {
    // R7-A5/B1 JS内截断：此前取整页outerHTML回包后再substring，
    // 大页CDP包即OOM。现maxChars进JS做slice，回包天然有界。
    final cap = maxChars.clamp(500, 20000);
    final r = await evaluate(
      '(function(n){var h=document.documentElement?document.documentElement.outerHTML:"";return h.length>n?h.slice(0,n):h;})($cap)',
      cdpTimeout: const Duration(seconds: 20),
    );
    final value = r['result']?['result']?['value'] ?? r['result']?['value'];
    // 空文档明确报错：about:blank 等无 documentElement 时 value 为 null，
    // 此前 '$value' 写成 "null" 字符串，模型误当正文。
    if (value == null) {
      throw StateError('页面无 document（空文档/未加载），请先 browser_open 有效页面');
    }
    var text = '$value';
    if (text.length > maxChars) {
      text = '${text.substring(0, maxChars)}…';
    }
    return text;
  }

  /// 等 selector 出现：JS 轮询（rAF+interval 混合），SPA 异步渲染兜底。
  /// 超时返回 false 不抛错，调用方降级为读当前快照。
  /// 转义走 JSON 传参通道：此前手拼 '\'' 在含换行/反引号时仍可断 JS。
  /// 导航世代守卫：等待开始时记录主连接 _targetUrl，中途变化（导航发生）
  /// 即早退 false——旧等待在新页命中同 selector 会误返 true。
  /// 清单高1：同进程 iframe 同样轮询——主文档未命中即扫同源 iframe
  /// contentDocument（一次 evaluate 内完成，无额外往返；跨进程 OOPIF
  /// 受同源策略不可达，走 DOM pierce/querySelectorNodeIdInFrames 口径，
  /// 全 miss 即 false 由调用方报"元素未出现"，不静默漂移）。
  Future<bool> waitForSelector(
    String selector, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    // 等待开始时的主连接 URL：中途 frameNavigated/targetInfoChanged 变更即导航。
    // R1-B4：世代键(url,loader)——同址SPA导航URL不变但loader换代，
    // 旧等待在新文档命中同selector误返true。现双键判定。
    final waitStartUrl = _targetUrl;
    final waitStartLoader = _targetLoaderId;
    // JSON 传参防引号逃逸：payload 经 base64 进 JS 再 JSON.parse，
    // 此前手拼 '\'' 包裹，selector 含换行/反引号/反斜杠仍可断 JS。
    // b64 只含 [A-Za-z0-9+/=]，拼进单引号 JS 字符串安全。
    // 第4轮N4：删 MutationObserver 死状态——observer 回调唯一效果是写
    // 无人读的 __myideMutHit='dirty'，对判定零影响纯 CPU 开销（busy 页面
    // 每次 DOM 变更都触发回调直至清理）；收敛时机与纯轮询版本一致。
    // 与 mutationWatchJs 平行实现共享全局变量有交叉污染隐患，一并清理。
    final b64 = base64Encode(utf8.encode(jsonEncode({'s': selector})));
    // R17-A3-2：预等待门穿透 shadow root 与同源 iframe——此前主文档
    // querySelector + 裸 iframe 扫描，open shadow root 内元素恒"元素未出现"
    // （TreeWalker/querySelector 不递归 shadowRoot 边界），click/fill/hover/
    // drag/select/scrollTo 全部以此为门即恒失败。现统一走 pierceHelperJs 的
    // __pierceQuery（主文档优先 + 同源 iframe + open shadow 递归），并支持
    // text=/xpath(//) 降级定位前缀（B2-5 定位兜底链的 wait 侧入口）。
    final expr =
        '$_pierceHelperJs'
        "(()=>{try{const bin=atob('$b64');"
        "const bytes=Uint8Array.from(bin,c=>c.charCodeAt(0));"
        "const json=(typeof TextDecoder!=='undefined'?new TextDecoder().decode(bytes):bin);"
        "const a=JSON.parse(json);"
        "function vis(el){if(!el) return 'no';"
        "try{const r=el.getBoundingClientRect();"
        "const st=getComputedStyle(el);"
        "return (r.width>0&&r.height>0&&st.visibility!=='hidden'&&st.display!=='none')?'yes':'hidden';"
        "}catch(_){return 'err';}}"
        "var el=null;"
        "try{var s0=a.s||'';"
        // B2-5：text= 前缀——按整页文本（含同源 iframe）匹配第一个可见候选。
        "if(s0.indexOf('text=')===0){var want=s0.slice(5).toLowerCase();var found=null;"
        "__pierceEach(function(e){if(found)return false;"
        "var t=(e.innerText||e.textContent||'').toLowerCase();"
        "if(t.indexOf(want)>=0){found=e;return false;}});el=found;}"
        // B2-5：xpath 前缀——按 roots 顺序 document.evaluate 求值。
        "else if(s0.indexOf('//')===0||s0.indexOf('(//')===0){var roots=__pierceRootsOfDoc();"
        "for(var ri=0;ri<roots.length&&!el;ri++){"
        "try{var it=roots[ri].evaluate(s0,roots[ri],null,XPathResult.FIRST_ORDERED_NODE_TYPE,null);"
        "if(it&&it.singleNodeValue)el=it.singleNodeValue;}catch(_){}}}"
        // A3-2：CSS selector 主路径——穿透同源 iframe + open shadow root。
        "else{try{el=__pierceQuery(s0);}catch(_){}}"
        "}catch(_){}"
        "var v=vis(el);if(v=='yes') return 'yes';"
        "return v;"
        "}catch(e){return 'err';}})()";
    while (DateTime.now().isBefore(deadline)) {
      // 导航世代守卫：中途主连接 URL 变化说明发生导航，旧等待作废早退。
      if (CdpClient.waitStaleForTest(
        waitStartUrl,
        _targetUrl,
        waitStartLoader: waitStartLoader,
        currentLoader: _targetLoaderId,
      )) {
        return false;
      }
      // R7-BR2：cdpTimeout贴外层剩余——此前固定10s，外层timeout更小时
      // 单次evaluate超外层deadline。小超时下不等满10s。
      final remain = deadline.difference(DateTime.now());
      if (remain <= Duration.zero) break;
      final budget = remain < const Duration(seconds: 10)
          ? remain
          : const Duration(seconds: 10);
      try {
        final r = await evaluate(expr, awaitPromise: false, cdpTimeout: budget);
        // R11-3-A 命中后二次比对loader：单次evaluate最长10s，期间pushState换文档
        // 后旧文档命中同selector即误返true。现命中后复检世代，换代即作废早退。
        if (CdpClient.waitStaleForTest(
          waitStartUrl,
          _targetUrl,
          waitStartLoader: waitStartLoader,
          currentLoader: _targetLoaderId,
        )) {
          return false;
        }
        final v =
            '${r['result']?['result']?['value'] ?? r['result']?['value'] ?? ''}';
        if (v == 'yes') {
          // 第4轮N4：命中即返——observer 死状态已删，无需 disconnect 清理。
          return true;
        }
      } catch (e) {
        // R5-BR3：关后秒回——此前catch吞掉CDP已关闭仍300ms轮询至10s超时。
        if ('$e'.contains('CDP 已关闭')) return false;
      }
      // R4-03：短轮询200ms——插入后一轮内命中（纯轮询口径，无 observer）。
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }
}
