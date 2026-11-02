/// 自研浏览器控制台与网络失败存储：纯 Dart，零第三方依赖。
/// 内嵌通道（JS 钩子）与 CDP 通道（Log/Network 事件）都只往这里写，
/// Agent 的 browser_console / browser_network_failures 只读这里。
class BrowserConsoleEntry {
  BrowserConsoleEntry({
    required this.type,
    required this.message,
    this.url,
    this.line,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  /// log | warn | error | pageError | unhandledrejection | exception | nav
  final String type;
  final String message;
  final String? url;
  final int? line;
  final DateTime time;

  /// R1-12：全局自增序号（push 时由 store 赋值）——导航清理按序号分界，
  /// 不再按环形缓冲长度下标（高频日志慢门禁下旧条逐出导致索引漂移）。
  int seq = -1;

  String format() {
    final u = url == null || url!.isEmpty
        ? ''
        : ' $url${line == null ? '' : ':$line'}';
    // 时间补齐：延迟/乱序事件此前无时序，排查无法排序。
    final t =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
    return '[$t][$type]$u $message';
  }
}

/// 环形缓冲：上限 500 条，超限丢最旧，保证内存有界。
class BrowserConsoleStore {
  BrowserConsoleStore({this.capacity = 500});

  /// 错误类型归一口径：与 AgentBrowserTools.errorTypes 对齐
  /// （chrome-devtools-mcp list_console_messages 错误过滤口径），
  /// 自检 health 分级只数这类，避免 info/log 刷屏误判 degraded。
  /// R1-Console：单源口径——此前assert/trace计错误，任意trace即degraded虚高。
  /// 现trace/debug/info/log不计错误（调试噪音），仅error/warn/pageError/
  /// exception/unhandledrejection计错（对标chrome-devtools-mcp）。
  static const errorKinds = {
    'error',
    'warn',
    'warning',
    'pageError',
    'onPageError',
    'unhandledrejection',
    'exception',
  };

  static String redactMessage(String raw) {
    var out = raw.replaceAll(RegExp(r'sk-[A-Za-z0-9_\-]{8,}'), 'sk-***');
    out = out.replaceAllMapped(
      RegExp(r'(Bearer\s+)[A-Za-z0-9._\-]{8,}', caseSensitive: false),
      (m) => '${m[1]}***',
    );
    // R11R2-01：键名单词边界——此前`key`无词界，`monkey=`等正常词被误杀。
    // 负向后瞻保证键名前非字母数字下划线；值分支覆盖双引号/单引号/裸值三种形态。
    // R-CONSOLE-KEYS：键名集合扩 api[-_]?key/auth/signature——负向后瞻使
    // `apikey=`（无下划线写法）中 `key` 前是字母被拒、`api_key` 不匹配，
    // 真实世界常见写法明文泄漏进模型上下文。
    out = out.replaceAllMapped(
      RegExp(
        "(?<![A-Za-z0-9_])((?:api[-_]?key|access[-_]?token|auth|signature|token|key)\\s*[=:]\\s*)(?:\"[^\"]{4,}\"|'[^']{4,}'|[^\\s&,\"']{4,})",
        caseSensitive: false,
      ),
      (m) => '${m[1]}***',
    );
    return out;
  }

  static String redactUrlQuery(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasQuery) return raw;
    // R11R2-02：掩码代替删除——此前敏感参数直接删除，失败URL不可复现
    // （删参后签名/分页全变）。现保留键、值掩码为***，可复现结构不泄值。
    // R-CONSOLE-KEYS：与 redactMessage 键集合同口径扩 apikey/auth/signature。
    const sensitive = {
      'token', 'api_key', 'api-key', 'apikey', 'access_token',
      'accesstoken', 'auth', 'authorization', 'signature', 'sig', 'key',
    };
    final kept = <String, String>{};
    var changed = false;
    uri.queryParameters.forEach((k, v) {
      if (sensitive.contains(k.toLowerCase())) {
        changed = true;
        kept[k] = '***';
        return;
      }
      kept[k] = v;
    });
    if (!changed) return raw;
    // Uri.replace 会把***编码为%2A%2A%2A，还原星号保持可读（*在query合法）。
    return uri
        .replace(queryParameters: kept.isEmpty ? null : kept)
        .toString()
        .replaceAll('%2A', '*');
  }

  final int capacity;
  final List<BrowserConsoleEntry> _entries = [];
  // R1-12：序号水位——push 单调递增，导航发起时快照、落地按序号分界。
  int _seq = 0;

  /// R1-12：下一条 push 的序号（导航发起时快照于此分界）。
  int get nextSeq => _seq;

  List<BrowserConsoleEntry> get entries => List.unmodifiable(_entries);

  /// R1-12：序号 ≥ [seq] 的现存条目（慢门禁窗口内新条保留分界口径）。
  List<BrowserConsoleEntry> entriesFromSeq(int seq) =>
      _entries.where((e) => e.seq >= seq).toList();

  void push(BrowserConsoleEntry entry) {
    // R15R5：单条有界4K——此前整条大 body 进环，500 条×超大即内存膨胀。
    // consoleAPICalled 已有 4k 口径，此处 push 层统一收口（内嵌钩子已限
    // 2000，CDP Log/错误体另有 2k/512K 口径，直调 pushText 同样收敛）。
    // url 同样有界：CDP data: URL 可达 MB 级，进 url 字段即绕过正文截断。
    final rawUrl = redactUrlQuery(entry.url ?? '');
    final url = rawUrl.length > 512
        ? '${rawUrl.substring(0, 512)}…（已截断，共 ${rawUrl.length} 字符）'
        : (rawUrl.isEmpty ? null : rawUrl);
    final redactedMsg = redactMessage(entry.message);
    final msg = redactedMsg.length > 4000
        ? '${redactedMsg.substring(0, 4000)}…（已截断，共 ${redactedMsg.length} 字符）'
        : redactedMsg;
    final bounded = (msg == entry.message && url == entry.url)
        ? entry
        : BrowserConsoleEntry(
            type: entry.type,
            message: msg,
            url: url,
            line: entry.line,
            time: entry.time,
          );
    // R1-12：push 即赋全局自增序号（修红act后条目也取新号，清理分界按此）。
    bounded.seq = _seq++;
    _entries.add(bounded);
    if (_entries.length > capacity) {
      // 错误保底：恶意页高频 log 刷环时错误被逐出，看错误能力丢失。
      // 超限先逐出非错误条；全为错误才按序丢最旧。
      final overflow = _entries.length - capacity;
      var removed = 0;
      // 第3轮R3-5续：逐出同样归一口径——此前裸errorKinds.contains+归一后type，
      // 大小写/别名稍有出入即把错误当非错误优先逐出。与errorCount同口径收敛。
      final want = errorKinds.map(normTypeForTest).toSet();
      _entries.removeWhere((e) {
        if (removed >= overflow) return false;
        if (!want.contains(_normType(e.type))) {
          removed++;
          return true;
        }
        return false;
      });
      if (_entries.length > capacity) {
        _entries.removeRange(0, _entries.length - capacity);
      }
    }
  }

  /// 类型归一单源（测试可见）：warning->warn，onPageError->pageError。
  /// R11R3-01：此前_normType/errorCount/tailWhere三处手写重复，新增类型即分裂。
  static String normTypeForTest(String t) {
    // 第3轮R3-5：大小写归一——此前ERROR/WARN按非错误逐出、不计errorCount、
    // tailWhere查不到。比较前小写，返回保持camelCase规范形（pageError），
    // 调用方传warn/pageError与存量warning/onPageError/ERROR全对得上。
    final v = t.trim().toLowerCase();
    if (v == 'warning' || v == 'warn') return 'warn';
    if (v == 'onpageerror' || v == 'pageerror') return 'pageError';
    return v;
  }

  static String _normType(String t) => normTypeForTest(t);

  void pushText(String type, String message, {String? url, int? line}) {
    push(
      BrowserConsoleEntry(type: type, message: message, url: url, line: line),
    );
  }

  /// 错误条数：按 errorKinds 归一口径统计（自检 health 分级用）。
  /// R-自检：只数错误类，避免 info/log 刷屏误判 degraded。
  int get errorCount {
    final want = errorKinds.map(normTypeForTest).toSet();
    var n = 0;
    for (final e in _entries) {
      if (want.contains(normTypeForTest(e.type))) n++;
    }
    return n;
  }

  /// 最近 [tail] 条，旧→新排列。
  List<BrowserConsoleEntry> tail(int n) {
    if (_entries.isEmpty) return const [];
    final take = n.clamp(1, _entries.length);
    final start = (_entries.length - take).clamp(0, _entries.length);
    return List.unmodifiable(_entries.sublist(start));
  }

  /// 按类型过滤的最近 N 条（Agent 只看 error 类时用）。
  /// R1-04：调用方集合已归一，此处再做同义词归一防直调漏检
  /// （warning->warn，onPageError->pageError）。
  /// R4-BR2：按URL过滤——多iframe各报错时可只看B。
  // ignore: avoid_renaming_method_parameters
  List<BrowserConsoleEntry> tailWhere(Set<String> types, int n, {String? urlContains}) {
    final filtered = entriesWhere(types: types, urlContains: urlContains);
    if (filtered.isEmpty) return const [];
    final take = n.clamp(1, filtered.length);
    return List.unmodifiable(filtered.sublist(filtered.length - take));
  }

  /// G2-4：全量过滤集（不取最近 N，供工具层分页切片），仍旧→新排列。
  /// types=null 即不过类型（全量，含 info/debug 等所有类型，比 allTypes 更全）；
  /// types 非空按归一口径过滤（同 tailWhere）。URL 召回口径与 tailWhere
  /// 同源（R1-A3：url 空时回退正文"当前页"后缀匹配，空归因可召回）。
  List<BrowserConsoleEntry> entriesWhere({
    Set<String>? types,
    String? urlContains,
  }) {
    final want = (types ?? const <String>{}).map(normTypeForTest).toSet();
    final q = (urlContains ?? '').trim();
    return List.unmodifiable(
      _entries.where((e) {
        if (types != null && !want.contains(normTypeForTest(e.type))) {
          return false;
        }
        if (q.isNotEmpty) {
          final u = e.url ?? '';
          if (u.contains(q)) return true;
          if (u.isEmpty && e.message.contains(q)) return true;
          return false;
        }
        return true;
      }),
    );
  }

  void clear() => _entries.clear();
}

class BrowserNetworkFailure {
  BrowserNetworkFailure({
    required this.url,
    required this.errorText,
    this.resourceType = '',
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final String url;
  final String errorText;

  /// G2-4：资源类型（CDP Network.loadingFailed/responseReceived 的 type，
  /// PascalCase 如 Document/Script/XHR/WebSocket；空=未知，type 过滤不命中）。
  final String resourceType;

  final DateTime time;

  /// R1-12：全局自增序号（push 时赋值），导航清理按序号分界。
  int seq = -1;

  String format() => '$url :: $errorText';
}

/// 网络失败记录：上限 200 条，去重（同 url+error 只保留最新）。
class BrowserNetworkStore {
  BrowserNetworkStore({this.capacity = 200});

  final int capacity;
  // R6-BR3：有序Map去重——此前 List+removeWhere 每推全扫 O(n)，
  // 高频失败页抖动。现 Map 键直达 O(1)，删后重插即搬尾保“最新”语义。
  final Map<String, BrowserNetworkFailure> _map = {};
  // R1-12：序号水位（去重重插即取新号，视作新条）。
  int _seq = 0;

  /// R1-12：下一条 push 的序号（导航发起时快照于此分界）。
  int get nextSeq => _seq;

  List<BrowserNetworkFailure> get items => List.unmodifiable(_map.values);

  /// R1-12：序号 ≥ [seq] 的现存条目。
  List<BrowserNetworkFailure> itemsFromSeq(int seq) =>
      _map.values.where((e) => e.seq >= seq).toList();

  static String _key(String url, String errorText) => '$url\u0000$errorText';

  /// D6：url/error 归一（redact+截断）——push/remove 共用，保证键一致
  /// （remove 归一口径与 push 不同即删不掉旧条）。
  static (String url, String errorText) _normalizeEntry(
    String url,
    String errorText,
  ) {
    final rawU = BrowserConsoleStore.redactUrlQuery(url);
    final rawE = BrowserConsoleStore.redactMessage(errorText);
    final u = rawU.length > 512 ? '${rawU.substring(0, 512)}…（已截断）' : rawU;
    final e = rawE.length > 2000
        ? '${rawE.substring(0, 2000)}…（已截断）'
        : rawE;
    return (u, e);
  }

  void push(String url, String errorText, {String? resourceType}) {
    // 与 console 同口径：url/error 同样有界，data: URL 不进无界键。
    final (u, e) = _normalizeEntry(url, errorText);
    final key = _key(u, e);
    _map.remove(key);
    // G2-4：resourceType 随条目记录（不进去重键——去重语义仍 url+error，
    // 同键重推以最新 resourceType 为准）。
    _map[key] = BrowserNetworkFailure(
      url: u,
      errorText: e,
      resourceType: resourceType ?? '',
    )..seq = _seq++;
    while (_map.length > capacity) {
      _map.remove(_map.keys.first);
    }
  }

  /// D6：删除指定 url+errorText 的旧条——loadingFailed 异步补请求体前
  /// 调用：补体 push 的新键（errorText 前缀同但多请求体行）与旧键不同，
  /// 不删则同一失败在网络表留两条（一条裸错误一条带体），破坏
  /// "一条网络失败记录"语义。归一与 push 同口径，键不存在时为空操作。
  void remove(String url, String errorText) {
    final (u, e) = _normalizeEntry(url, errorText);
    _map.remove(_key(u, e));
  }

  List<BrowserNetworkFailure> tail(int n) {
    final all = _map.values.toList();
    if (all.isEmpty) return const [];
    final take = n.clamp(1, all.length);
    return List.unmodifiable(all.sublist(all.length - take));
  }

  /// R5-BR1：按URL过滤的最近N条——console R4已补tailWhere(urlContains)，
  /// network此前仅tail，多iframe无法只看B。工具层透传urlContains。
  // ignore: avoid_renaming_method_parameters
  List<BrowserNetworkFailure> tailWhere(int n, {String? urlContains}) {
    final filtered = itemsWhere(urlContains: urlContains);
    if (filtered.isEmpty) return const [];
    final take = n.clamp(1, filtered.length);
    return List.unmodifiable(filtered.sublist(filtered.length - take));
  }

  /// G2-4：全量过滤集（不取最近 N，供工具层分页切片），仍旧→新排列。
  /// URL 召回口径与 tailWhere 同源（R11R1-02：空 URL 条目不过滤，
  /// 未知归因保守保留，排查多 iframe 不丢证据）。
  List<BrowserNetworkFailure> itemsWhere({String? urlContains}) {
    final q = (urlContains ?? '').trim();
    if (q.isEmpty) return List.unmodifiable(_map.values);
    return List.unmodifiable(
      _map.values.where((e) => e.url.isEmpty || e.url.contains(q)),
    );
  }

void clear() => _map.clear();
}

/// B14：全量请求表条目（含成功请求）——排查成功但慢/大的请求、
/// 定位资源归属（哪一帧发起）、统计请求数。
class BrowserRequestRecord {
  BrowserRequestRecord({
    required this.requestId,
    required this.url,
    this.resourceType = '',
    this.statusCode = 0,
    this.errorText = '',
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final String requestId;
  final String url;
  final String resourceType;

  /// HTTP 状态码；0=未收响应（请求中/失败）。非 final：迟到响应补值时
  /// 已入表的记录需就地更新（重建记录会丢 seq/time 顺序语义）。
  int statusCode = 0;

  /// loadingFailed 的错误文本；成功请求为空。
  final String errorText;

  final DateTime time;
  int seq = -1;

  /// 展示口径：requestId url :: status（失败带错误文本）。
  String format() {
    final status = statusCode > 0 ? '$statusCode' : '—';
    final err = errorText.isEmpty ? '' : ' :: $errorText';
    return '$requestId $url :: $status$err';
  }
}

/// B14：全量请求表——上限 [capacity] 条，按 requestId 去重（重推更新同条），
/// 旧→新排列供分页切片。与 BrowserNetworkStore（失败口径）并存：
/// 失败仍进 networkFailures（含错误体），全量表只供排查成功请求。
class BrowserRequestStore {
  BrowserRequestStore({this.capacity = 500});

  final int capacity;
  final Map<String, BrowserRequestRecord> _map = {};
  int _seq = 0;

  int get nextSeq => _seq;
  int get length => _map.length;
  List<BrowserRequestRecord> get items => List.unmodifiable(_map.values);

  List<BrowserRequestRecord> itemsFromSeq(int seq) =>
      _map.values.where((e) => e.seq >= seq).toList();

  /// 归一与 BrowserNetworkStore 同口径：url/文本同样脱敏与截断，键一致。
  static (String url, String err) _normalize(String url, String err) {
    final rawU = BrowserConsoleStore.redactUrlQuery(url);
    final rawE = BrowserConsoleStore.redactMessage(err);
    final u = rawU.length > 512 ? '${rawU.substring(0, 512)}…（已截断）' : rawU;
    final e = rawE.length > 2000
        ? '${rawE.substring(0, 2000)}…（已截断）'
        : rawE;
    return (u, e);
  }

  /// 请求发起登记（requestWillBeSent 口径）：state=进行中。
  void add(
    String requestId,
    String url, {
    String? resourceType,
  }) {
    final id = requestId.trim();
    if (id.isEmpty) return;
    final (u, e) = _normalize(url, '');
    _map[id] = BrowserRequestRecord(
      requestId: id,
      url: u,
      resourceType: resourceType ?? '',
    )..seq = _seq++;
    while (_map.length > capacity) {
      _map.remove(_map.keys.first);
    }
  }

  /// 响应到达登记（responseReceived 口径）：更新状态码与资源类型。
  void markResponse(
    String requestId, {
    required int statusCode,
    String? resourceType,
    String? url,
  }) {
    final id = requestId.trim();
    if (id.isEmpty) return;
    final old = _map[id];
    if (old == null) {
      // 未登记的迟到响应（映射淘汰/事件丢失）：补建一条，排查不丢证据。
      add(id, url ?? '', resourceType: resourceType);
      final created = _map[id];
      if (created != null) created.statusCode = statusCode;
      return;
    }
    final (u, _) = _normalize(url ?? old.url, old.errorText);
    _map[id] = BrowserRequestRecord(
      requestId: id,
      url: u,
      resourceType: resourceType ?? old.resourceType,
      statusCode: statusCode,
      errorText: old.errorText,
      time: old.time,
    )..seq = old.seq;
  }

  /// 失败登记（loadingFailed 口径）：写错误文本（保留原状态码）。
  void markFailed(String requestId, String errorText) {
    final id = requestId.trim();
    if (id.isEmpty) return;
    final old = _map[id];
    if (old == null) return;
    final (u, e) = _normalize(old.url, errorText);
    _map[id] = BrowserRequestRecord(
      requestId: id,
      url: u,
      resourceType: old.resourceType,
      statusCode: old.statusCode,
      errorText: e,
      time: old.time,
    )..seq = old.seq;
  }

  List<BrowserRequestRecord> tail(int n) {
    final all = _map.values.toList();
    if (all.isEmpty) return const [];
    final take = n.clamp(1, all.length);
    return List.unmodifiable(all.sublist(all.length - take));
  }

  List<BrowserRequestRecord> tailWhere(
    int n, {
    String? urlContains,
  }) {
    final filtered = itemsWhere(urlContains: urlContains);
    if (filtered.isEmpty) return const [];
    final take = n.clamp(1, filtered.length);
    return List.unmodifiable(filtered.sublist(filtered.length - take));
  }

  /// 全量过滤集（不取最近 N，供工具层分页切片），仍旧→新排列。
  List<BrowserRequestRecord> itemsWhere({
    String? urlContains,
    String? type,
    String? status,
  }) {
    var out = List<BrowserRequestRecord>.of(_map.values);
    final q = (urlContains ?? '').trim();
    if (q.isNotEmpty) {
      out = out.where((e) => e.url.isEmpty || e.url.contains(q)).toList();
    }
    final t = (type ?? '').trim().toLowerCase();
    if (t.isNotEmpty) {
      out = out
          .where((e) => e.resourceType.trim().toLowerCase() == t)
          .toList();
    }
    final s = (status ?? '').trim().toLowerCase();
    if (s.isNotEmpty) {
      // status 过滤：success=2xx；failure=4xx/5xx；pending=无响应。
      // 其余显式状态码前缀匹配（"200"/"200,206" 逗号分隔多值）。
      out = out.where((e) {
        final code = e.statusCode;
        switch (s) {
          case 'success':
            return code >= 200 && code < 300;
          case 'failure':
            return code >= 400;
          case 'pending':
            return code <= 0;
        }
        if (s.contains(',')) {
          return s.split(',').any((part) => '$code'.startsWith(part.trim()));
        }
        return '$code' == s || '$code'.startsWith(s);
      }).toList();
    }
    return out;
  }

  void clear() => _map.clear();
}
