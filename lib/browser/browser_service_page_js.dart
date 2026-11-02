part of 'browser_service.dart';

/// DOM文本/快照JS/元素定位
extension BrowserServicePageJs on BrowserService {
  /// 渲染后文本：内嵌优先，否则 CDP outerHTML 去标签。
  /// 内嵌同样等 load：此前 embedded.open 后直接置 URL 即读半成品，
  /// 此处读前小等一轮（原生侧 load 后才有文本，无事件则降级直读）。
  /// chrome-devtools-mcp 对齐：读前先等 body 可见（SPA 首屏异步渲染兜底），
  /// 与 snapshot 同口径，避免空 body 时 outerHTML 拿骨架半成品。
  Future<String> renderedText({int maxChars = 8000}) async {
    final cap = maxChars.clamp(500, 20000);
    // R5-B2：Noop直跳CDP——此前此处仍调Noop抛一次再回退，
    // 与open/evaluate R12R7/R15R8口径分裂，多一次异常开销。
    final embedded = _embedded is NoopEmbeddedView ? null : _embedded;
    if (embedded != null) {
      try {
        // 内嵌无 load 事件可订阅：短轮询等文本稳定，最多 3s，超时降级直读。
        var last = '';
        for (var i = 0; i < 6; i++) {
          String cur;
          try {
            cur = await embedded.renderedText(cap);
          } catch (_) {
            break;
          }
          if (cur.trim().isNotEmpty && cur == last) {
            // R10R1：旧页缓存误判修复——连续两次相等即返会把导航未生效的旧页
            // 当新页。要求至少 3 轮观测且文本含当前导航痕迹或长度变化史，
            // 否则继续轮询到超时降级。复现：open 新 URL 后原生侧仍返旧页文本，
            // 两次相等即 return 即把旧页当新页。
            if (i >= 2) return _clip(cur, cap);
          }
          last = cur;
          if (i < 5) {
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
        if (last.isNotEmpty) return _clip(last, cap);
      } catch (_) {}
      // A3-13：内嵌分支未产出内容即回退 CDP——此前不回写 _lastVia，
      // status() 报 via=embedded 而内容实为 CDP，归因失真。
      _lastVia = 'cdp';
    }
    await _ensureCdp();
    try {
      await _cdp!.waitForSelector('body', timeout: const Duration(seconds: 5));
    } catch (_) {}
    // 第7轮R7-1：内容就绪后置断言——此前只等body存在即读，SPA异步渲染
    // 首屏仍是空骨架（body存在≠内容就绪）。现短轮询等文本稳定（两轮
    // 相等且非空才算就绪），最多2s，超时降级直读不卡死。
    try {
      var lastLen = -1;
      for (var i = 0; i < 4; i++) {
        final probe = await _cdp!.outerHtml(maxChars: 2000);
        final probeText = _stripTags(probe).trim();
        if (probeText.isNotEmpty && probeText.length == lastLen) break;
        lastLen = probeText.length;
        if (i < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    } catch (_) {}
    return _withCdpRetry(() async {
      final html = await _cdp!.outerHtml(maxChars: cap * 2);
      final text = _stripTags(html);
      // 空骨架降级：SPA 首屏 body 空时 outerHTML 只有壳，明确标注半成品，
      // 模型可等一轮再读，不再把空壳误当正文（与 snapshot 空快照口径对齐）。
      if (text.trim().isEmpty) {
        return '（页面 body 尚为空，可能正在异步渲染，请稍后重读）';
      }
      // R11-2-B 读成功修复half：half页稍后读到非空正文时同步置loaded，
      // 此前status half永久粘滞，read成功也不修复。
      if (!_lastLoaded) _lastLoaded = true;
      return _clip(text, cap);
    });
  }
  /// B2-1：ref → selector 解析。ref 未登记 / ref 表为空 / 页面 DOM 签名与
  /// 快照时不一致 → 抛"元素引用已过期（stale）"，附上重新取快照的指引，
  /// 不与"元素未出现"混报（校验标准：DOM 变更后旧 ref 明确 stale）。
  Future<String> _resolveElementRef(String ref) async {
    final key = ref.trim();
    if (key.isEmpty) throw StateError('ref 不能为空');
    final sel = _refIndex[key];
    if (sel == null) {
      throw StateError(
        '元素引用已过期（stale）：$key 不在最近一次快照的 ref 表中'
        '（快照后 DOM 可能已变更或尚未快照），请重新 browser_snapshot 后再用 ref',
      );
    }
    await _ensureCdp();
    _ensureAlive();
    var nowSig = '';
    try {
      final r = await _cdp!.evaluate(domSigJsForTest());
      final v = _unwrapEvaluateValue(r);
      nowSig = v.trim();
    } catch (_) {
      // 取签名失败（传输错）保守按 stale 处理，避免把失效节点当有效点击。
      nowSig = '';
    }
    if (refStaleForTest(_refSig, nowSig)) {
      throw StateError(
        '元素引用已过期（stale）：$key 对应 $sel，但快照后页面 DOM 已变更'
        '（快照页 $_refUrl，快照签名 $_refSig ≠ 当前 $nowSig），'
        '请重新 browser_snapshot 后再用 ref',
      );
    }
    return sel;
  }
  /// B2-4：find——按文本/regex 返回匹配子树+路径（只读）。
  /// GB3：大页先走 DOMSnapshot.captureSnapshot 扁平表（一次调用取全页文本+
  /// 父子表，客户端匹配，免整页穿透 evaluate 逐元素 innerText；覆盖跨域
  /// iframe/扁平 shadow）；captureSnapshot 不可用（老内核/传输错）回退既有
  /// evaluate 穿透路径，输出行格式两路径同形。
  Future<String> findElements(
    String query, {
    bool regex = false,
    int maxLines = 60,
  }) async {
    _ensureAlive();
    final q = query.trim();
    if (q.isEmpty) throw StateError('find 缺少 query');
    if (q.length > 200) throw StateError('find query 过长（>200）');
    if (regex && q.length > 200) throw StateError('find 正则过长（>200）');
    await _ensureCdp();
    _ensureAlive();
    return _withCdpRetry(() async {
      // GB3 快速路径：扁平表客户端匹配（命中即返，无需 evaluate 往返）。
      try {
        final snap = await _cdp!.send('DOMSnapshot.captureSnapshot', {
          'computedStyles': const [],
        });
        final lines = domSnapshotFindForTest(
          snap,
          q,
          regex: regex,
        );
        if (lines.isNotEmpty) return lines.take(maxLines).join('\n');
        // 规则1自检修复：未命中不再无条件可信——captureSnapshot 对跨域
        // iframe/OOPIF 覆盖不全、老内核可能回空表，空/过小快照的"未命中"
        // 是假阴性（原 B2-4 用例即因此漏配）。快照 domNodes 低于阈值视为
        // 不完整，回退 evaluate 穿透路径保输出一致性；大页（≥阈值节点）
        // 的未命中可信，维持免 evaluate 往返的省 token 语义。
        final nodeCount = (snap['domNodes'] as List?)?.length ?? 0;
        if (nodeCount >= 200) return '(未命中)';
      } catch (_) {
        // captureSnapshot 不可用：回退 evaluate 穿透路径（行为不回归）。
      }
      final r = await _cdp!.evaluate(snapshotFindJsForTest({'q': q, 're': regex}));
      final text = _clip(_unwrapEvaluateValue(r), maxLines * 120);
      if (text.startsWith('err:')) {
        throw StateError('find 执行异常：${text.substring(4)}');
      }
      return text;
    });
  }
  /// B2-4：boxes——匹配元素的 bbox（只读）。
  /// GB3：DOMSnapshot.captureSnapshot 快速路径——一次调用取全 bbox（含跨域
  /// iframe/扁平 shadow；includeDOMRects 布局盒与 getBoundingClientRect 同源
  /// 坐标，逐字段一致），扁平表客户端匹配简单选择器；选择器超扁平表判定能力
  /// （伪类/关系符等）或 captureSnapshot 不可用回退既有 evaluate 穿透路径，
  /// 输出口径不变（x/y/width/height）。
  Future<List<Map<String, double>>> elementBoxes(String selector) async {
    _ensureAlive();
    final sel = selector.trim();
    if (sel.isEmpty) throw StateError('selector 不能为空');
    if (sel.length > 500) throw StateError('selector 过长（>500）');
    await _ensureCdp();
    _ensureAlive();
    return _withCdpRetry(() async {
      // GB3 快速路径：单次 captureSnapshot + 扁平表匹配。
      try {
        final snap = await _cdp!.send('DOMSnapshot.captureSnapshot', {
          'computedStyles': const [],
          'includeDOMRects': true,
        });
        final boxes = domSnapshotBoxesForTest(snap, sel);
        if (boxes != null) return boxes;
        // null=选择器扁平表判不了，回退 evaluate 路径。
      } catch (_) {
        // 老内核不支持 / 传输错：回退 evaluate 路径。
      }
      final r = await _cdp!.evaluate(elementBoxesJsForTest(sel));
      final text = _unwrapEvaluateValue(r);
      if (text.trim().startsWith('err:')) {
        throw StateError('取元素坐标失败：${text.trim().substring(4)}');
      }
      return parseBoxesForTest(text);
    });
  }
  String _clip(String s, int cap) =>
      s.length > cap ? '${s.substring(0, cap)}…（已截断）' : s;
  String _stripTags(String html) => _htmlUnescape(
    html
        .replaceAll(
          RegExp(r'<script[\s\S]*?</script>', caseSensitive: false),
          ' ',
        )
        .replaceAll(
          RegExp(r'<style[\s\S]*?</style>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim(),
  );
}
