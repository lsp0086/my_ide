part of 'chrome_cdp.dart';

/// DOM 查询与定位：selector→nodeId（主文档/帧内穿透）、节点内容 quad。

/// R1-H1 纯函数：从 pierce 展平 DOM 树收集全部文档节点 id
/// （nodeName == '#document'），供逐文档 querySelector。
List<int> collectDocumentNodeIds(dynamic node) {
  final out = <int>[];
  void walk(dynamic n) {
    if (n is! Map) return;
    final name = '${n['nodeName'] ?? ''}';
    final id = (n['nodeId'] as num?)?.toInt() ?? 0;
    if (name == '#document' && id > 0) out.add(id);
    // B1：shadow root 节点（shadowRootType 标记）同样可作为
    // DOM.querySelector 的 root nodeId——此前只收 #document，
    // shadow DOM 内元素永报"元素未出现"（Playwright CSS 默认穿透
    // open shadow root，本项目对齐该口径）。
    final shadowType = '${n['shadowRootType'] ?? ''}';
    if (shadowType.isNotEmpty && id > 0) out.add(id);
    final children = n['children'];
    if (children is List) {
      for (final c in children) {
        walk(c);
      }
    }
    final content = n['contentDocument'];
    if (content is Map) walk(content);
    // shadowRoots 数组（DOM.getDocument depth:-1 时返回）
    final shadowRoots = n['shadowRoots'];
    if (shadowRoots is List) {
      for (final s in shadowRoots) {
        walk(s);
      }
    }
  }

  walk(node);
  return out;
}

extension CdpClientDom on CdpClient {
  /// D1（测试可见）：selector → DOM nodeId（主会话）——DOM.getDocument
  /// (depth:0) 取根节点再 DOM.querySelector；未命中（nodeId=0）返回 null
  /// 由调用方报错。click/fill 元素定位走 DOM 域而非 JS evaluate。
  /// 来源 https://chromedevtools.github.io/devtools-protocol/tot/DOM/。
  Future<int?> querySelectorNodeId(String selector) async {
    final doc = await send('DOM.getDocument', {'depth': 0});
    final root = ((doc['root'] as Map?)?['nodeId'] as num?)?.toInt() ?? 0;
    if (root <= 0) return null;
    final r = await send('DOM.querySelector', {
      'nodeId': root,
      'selector': selector,
    });
    final id = (r['nodeId'] as num?)?.toInt() ?? 0;
    if (id > 0) return id;
    // R1-H1：主文档未命中即穿透 iframe——此前只查主根，帧内元素永报
    // "元素未出现"。现取 pierce 展平树收集各文档节点逐个 querySelector。
    return querySelectorNodeIdInFrames(selector);
  }

  /// R1-H1：帧内元素查询——DOM.getDocument(pierce:true,depth:-1) 展平树
  /// （含 iframe contentDocument 节点，见 DOM 域 "iframe owner elements
  /// will return corresponding document elements as their child nodes"，
  /// https://chromedevtools.github.io/devtools-protocol/tot/DOM/），收集
  /// 全部 #document 节点逐个 DOM.querySelector，命中即返。cross-origin
  /// OOPIF 走独立 target/session，主连接查不到即返 null（调用方报错，
  /// 不静默漂移）。校验：含 cross-origin iframe 页对帧内元素 wait/click
  /// 应命中而非"元素未出现"（同进程帧）。
  Future<int?> querySelectorNodeIdInFrames(String selector) async {
    Map<String, dynamic> doc;
    try {
      doc = await send('DOM.getDocument', {'depth': -1, 'pierce': true});
    } catch (_) {
      return null;
    }
    final root = doc['root'];
    if (root is! Map) return null;
    final docIds = collectDocumentNodeIds(root);
    for (final docId in docIds) {
      try {
        final r = await send('DOM.querySelector', {
          'nodeId': docId,
          'selector': selector,
        });
        final id = (r['nodeId'] as num?)?.toInt() ?? 0;
        if (id > 0) return id;
      } catch (_) {}
    }
    return null;
  }

  /// D1：节点内容 quad（8 数四角 x1y1x2y2x3y3x4y4）——DOM.getContentQuads
  /// 优先（CSS 变换后真实绘制四边形），失败/为空回退 DOM.getBoxModel 的
  /// content quad；两者全失败抛错（任务口径：无 JS 合成兜底，quad/box 全
  /// 失败即报错）。坐标为主 frame 视口 CSS 像素（Input 域同口径）。
  Future<List<double>> nodeContentQuad(int nodeId) async {
    Object? quad;
    try {
      final r = await send('DOM.getContentQuads', {'nodeId': nodeId});
      final quads = r['quads'];
      if (quads is List && quads.isNotEmpty) quad = quads.first;
    } catch (_) {
      quad = null;
    }
    if (quad is! List || quad.length != 8) {
      final r = await send('DOM.getBoxModel', {'nodeId': nodeId});
      quad = (r['model'] as Map?)?['content'];
    }
    if (quad is! List || quad.length != 8) {
      throw StateError('无法获取元素位置（quad/box 均失败或数据非法）');
    }
    final out = <double>[];
    for (final v in quad) {
      if (v is! num) throw StateError('无法获取元素位置（quad 非 8 数四角）');
      out.add(v.toDouble());
    }
    return out;
  }
}
