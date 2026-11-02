part of 'browser_service.dart';

  // ── B2-5：定位兜底链（CSS → role= → text= → xpath）──────────────────────

  /// B2-5 定位兜底链 JS：CSS/DOM 域未命中时降级求值。命中返回
  /// `x,y,via`（via 注明命中路径）；'no'=未命中、'hidden'=不可见、
  /// 'err:*'=执行异常（调用方按需降级/报错）。

String locatorPointJsForTest(String selector) {
    final b64 = base64Encode(utf8.encode(jsonEncode({'s': selector})));
    return '${CdpClient.pierceHelperJs}'
        "(()=>{try{const bin=atob('$b64');"
        'const bytes=Uint8Array.from(bin,c=>c.charCodeAt(0));'
        "const json=(typeof TextDecoder!=='undefined'?new TextDecoder().decode(bytes):bin);"
        'const a=JSON.parse(json);'
        "var r=__pierceLocate(a.s);if(!r||!r.el) return 'no';"
        "if(!__pierceVisible(r.el)) return 'hidden';"
        'var b=r.el.getBoundingClientRect();'
        "return (b.x+b.width/2)+','+(b.y+b.height/2)+','+(r.via||'');"
        "}catch(e){return 'err:'+e;}})()";
  }


  /// B2-5 兜底链解析纯函数（测试可见）：JS 回包 → 坐标+命中路径，null=未命中。

({double x, double y, String via})? parseLocatorPointForTest(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t == 'no' || t == 'hidden' || t.startsWith('err:')) {
      return null;
    }
    final parts = t.split(',');
    if (parts.length < 2) return null;
    final x = double.tryParse(parts[0].trim());
    final y = double.tryParse(parts[1].trim());
    if (x == null || y == null) return null;
    return (x: x, y: y, via: parts.sublist(2).join(',').trim());
  }


  /// B2-5：最近一次动作的定位命中路径（css=主链路 DOM 域命中；role=/text=/
  /// xpath= 兜底链命中）。工具层据此在输出里注明"怎么找到的"。

List<String> locatorFallbackCandidatesForTest(String selector) {
    final s = selector.trim();
    if (s.isEmpty) return const [];
    if (s.startsWith('role=') ||
        s.startsWith('text=') ||
        s.startsWith('//') ||
        s.startsWith('(//')) {
      return [s];
    }
    final out = <String>[];
    final tag = RegExp(r'^([A-Za-z][A-Za-z0-9]*)')
            .firstMatch(s)
            ?.group(1)
            ?.toLowerCase() ??
        '';
    const roleByTag = {
      'button': 'button',
      'a': 'link',
      'input': 'textbox',
      'select': 'combobox',
      'textarea': 'textbox',
      'img': 'img',
      'summary': 'button',
    };
    final role = roleByTag[tag];
    if (role != null) out.add('role=$role');
    final token = RegExp(r'#([A-Za-z0-9_\-]+)').firstMatch(s)?.group(1) ??
        RegExp(r'\.([A-Za-z0-9_\-]+)').firstMatch(s)?.group(1);
    if (token != null && token.length >= 3) {
      out.add('text=$token');
      final spaced = token.replaceAll(RegExp(r'[-_]+'), ' ');
      if (spaced != token) out.add('text=$spaced');
    }
    return out;
  }


  /// B2-5：按兜底候选链取点击中心点（一次 evaluate 一个候选，命中即返）。
  /// 命中返回 (x, y, via)；全不命中返回 null（调用方按 absentMessage 报错）。

Map<String, dynamic> harFromRecordsForTest(
    List<BrowserRequestRecord> records, {
    String? pageUrl,
  }) {
    String iso(DateTime t) => t.toUtc().toIso8601String();
    final entries = <Map<String, dynamic>>[
      for (final r in records)
        <String, dynamic>{
          'pageref': 'page_1',
          'startedDateTime': iso(r.time),
          'time': 0,
          'request': <String, dynamic>{
            'method': 'GET',
            'url': r.url,
            'httpVersion': 'HTTP/1.1',
            'headers': <Map<String, String>>[],
            'queryString': <Map<String, String>>[
              for (final q in Uri.tryParse(r.url)?.queryParametersAll.entries
                      .expand((e) => e.value.map((v) => MapEntry(e.key, v))) ??
                  const <MapEntry<String, String>>[])
                {'name': q.key, 'value': q.value},
            ],
            'cookies': <Map<String, dynamic>>[],
            'headersSize': -1,
            'bodySize': 0,
          },
          'response': <String, dynamic>{
            'status': r.statusCode,
            // 原因短语（如 "OK"/"404 Not Found"）本实现不采集，留空由
            // DevTools 按 status 码自行补显示。
            'statusText': '',
            'httpVersion': '',
            'headers': <Map<String, String>>[],
            'cookies': <Map<String, dynamic>>[],
            'content': <String, dynamic>{
              'size': 0,
              'mimeType': r.resourceType,
            },
            'redirectURL': '',
            'headersSize': -1,
            'bodySize': -1,
          },
          'cache': <String, dynamic>{},
          'timings': <String, dynamic>{
            'blocked': -1,
            'dns': -1,
            'connect': -1,
            'send': 0,
            'wait': 0,
            'receive': 0,
            'ssl': -1,
          },
          'serverIPAddress': '',
          'connection': '',
          '_resourceType': r.resourceType,
          if (r.errorText.isNotEmpty) '_errorText': r.errorText,
        },
    ];
    return <String, dynamic>{
      'log': <String, dynamic>{
        'version': '1.2',
        'creator': <String, dynamic>{
          'name': 'my_ide',
          'version': '1.0',
          'comment': 'exported from my_ide self-built browser network store',
        },
        'pages': <Map<String, dynamic>>[
          <String, dynamic>{
            'startedDateTime': entries.isEmpty
                ? iso(DateTime.now())
                : entries.first['startedDateTime'],
            'id': 'page_1',
            'title': pageUrl ?? '',
            'pageTimings': <String, dynamic>{'onContentLoad': -1, 'onLoad': -1},
          },
        ],
        'entries': entries,
      },
    };
  }


String _unwrapEvaluateValue(Map<String, dynamic> r) {
    final inner = r['result']?['result'] ?? r['result'];
    String text;
    try {
      text = jsonEncode(inner);
    } catch (_) {
      text = '$inner';
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map && decoded['value'] is String) {
        return decoded['value'] as String;
      }
    } catch (_) {}
    return text;
  }


  /// R10R1 纯读 JS 判定：回退 CDP 仅限无副作用读口径。

bool isReadOnlyJsForTest(String js) => _isReadOnlyJs(js);


bool _isReadOnlyJs(String js) {
    final t = js.trim();
    if (t.isEmpty) return true;
    // R5-03 先剥字符串字面量：'.click('/"x.click("等写关键词出现在引号内
    // 只是读文本，此前直接contains误判写。单/双/反引号均剥离（转义感知）。
    final code = _stripStringLiterals(t);
    final lower = code.toLowerCase();
    // 写口径关键词：赋值/调用写 API/存储/网络/跳转即判有副作用。
    // R12R7：'function('/'=>' 移出——函数定义/箭头回调本身无副作用，
    // 此前纯读 `arr.map(x => x.text)` 被判写致内嵌失败后不回退 CDP。
    // 补 sendBeacon/import(：此前漏判写致双引擎各跑一遍。
    // R2-BR9：location裸子串误杀纯读——`location.href`读取/
    // `.location-label`类名此前判写，纯读回退CDP被拦。现location只认
    // 写形态（赋值/assign/replace/reload），裸读走下方词界判定。
    const writeMarks = [
      'localstorage',
      'sessionstorage',
      'indexeddb',
      'fetch(',
      'xmlhttprequest',
      'websocket',
      'location=',
      'location.href=',
      'location.assign(',
      'location.replace(',
      'location.reload(',
      'document.cookie',
      'document.write',
      '.click(',
      '.submit(',
      '.value=',
      '.innerhtml=',
      '.outerhtml=',
      '.remove(',
      '.append',
      '.insert',
      'eval(',
      'sendbeacon',
      'import(',
      // R4-写口径补齐：表单/存储/剪贴板/通知/分享/弹窗写 API 此前漏判，
      // 内嵌失败后回退 CDP 即双引擎各跑一遍副作用。
      // 路由/剪贴板读同样有副作用：pushState 改地址致后续读错页，
      // clipboard.readText 弹权限，两者均不得双跑。
      'formdata(',
      'setitem(',
      'removeitem(',
      'clear(',
      'execcommand(',
      'navigator.clipboard',
      'clipboard.readtext',
      'history.pushstate',
      'history.replacestate',
      'navigator.share(',
      'notification(',
      'alert(',
      'confirm(',
      'prompt(',
      // R3-B9：漏判写补齐——delete/自增/数组改写/DOM 属性改写/路由回退/
      // hash 与 search 赋值/Worker 与 serviceWorker 均无副作用判定豁免，
      // 内嵌失败后回退 CDP 即双引擎各跑一遍副作用（复现：eval('a++')
      // 内嵌抛错后应判写不再回退）。
      'delete ',
      '++',
      '--',
      'object.assign(',
      'object.defineproperty(',
      '.push(',
      '.pop(',
      '.splice(',
      '.setattribute(',
      '.classlist.',
      'history.go(',
      'history.back(',
      'history.forward(',
      'location.hash=',
      'location.search=',
      'new worker(',
      'serviceworker',
      // R10-A1：定时/观察/存储事件漏判写补齐——setTimeout/setInterval/
      // requestAnimationFrame/MutationObserver.observe 定时回调此前判读，
      // 内嵌失败后回退 CDP 即回调挂两遍（写回调双跑）；storage 事件监听
      // 同理。现统一判写，内嵌失败直接抛不再回退。
      'settimeout(',
      'setinterval(',
      'requestanimationframe(',
      'mutationobserver(',
      '.observe(',
      'addeventlistener(',
      'dispatchevent(',
    ];
    for (final m in writeMarks) {
      if (lower.contains(m)) return false;
    }
    // R1-T4：箭头/比较/正则/注释中的=不算写——此前`[=;]\s*\S+t.contains('=')`
    // 把`x => x.text`/`a==b`/`/=/`判写。现剥注释后只认裸`=`赋值：
    // 去掉==/===/!=/=>/<=/>=后仍有单`=`才算写。
    final noComment = _stripJsComments(code);
    final noCmp = noComment
        .replaceAll('===', '')
        .replaceAll('!==', '')
        .replaceAll('==', '')
        .replaceAll('!=', '')
        .replaceAll('=>', '')
        .replaceAll('<=', '')
        .replaceAll('>=', '');
    if (noCmp.contains('=')) return false;
    return true;
  }


  /// R5-03 剥字符串字面量（测试可见）：单/双/反引号转义感知剥离，
  /// 写关键词仅出现在引号内时不误判。

String stripStringLiteralsForTest(String src) =>
      _stripStringLiterals(src);


String _stripStringLiterals(String src) {
    final out = StringBuffer();
    var i = 0;
    while (i < src.length) {
      final c = src[i];
      if (c == "'" || c == '"' || c == '`') {
        final q = c;
        i++;
        while (i < src.length) {
          if (src[i] == '\\' && i + 1 < src.length) {
            i += 2;
            continue;
          }
          // R3-B9：模板字面量 `${}` 内是可执行表达式——先前整体剥离，
          // `tmp`${doWrite()}`` 中的写调用被判读漏防。现把插值体
          // 原样透传（只剥字符串部分），插值表达式继续参与写口径判定。
          if (q == '`' && src[i] == '\$' && i + 1 < src.length && src[i + 1] == '{') {
            var depth = 0;
            do {
              if (src[i] == '{') depth++;
              if (src[i] == '}') depth--;
              out.write(src[i]);
              i++;
            } while (i < src.length && depth > 0);
            continue;
          }
          if (src[i] == q) {
            i++;
            break;
          }
          i++;
        }
        out.write('""');
      } else {
        out.write(c);
        i++;
      }
    }
    return out.toString();
  }


  /// R1-T4：剥JS行/块注释（字符串已先剥离，此处`//`不再怕URL）。

String _stripJsComments(String src) {
    final out = StringBuffer();
    var i = 0;
    while (i < src.length) {
      if (src[i] == '/' && i + 1 < src.length && src[i + 1] == '/') {
        while (i < src.length && src[i] != '\n') {
          i++;
        }
        out.write('\n');
        continue;
      }
      if (src[i] == '/' && i + 1 < src.length && src[i + 1] == '*') {
        i += 2;
        while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
          i++;
        }
        i += 2;
        out.write(' ');
        continue;
      }
      out.write(src[i]);
      i++;
    }
    return out.toString();
  }
