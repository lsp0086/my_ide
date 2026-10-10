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
    out = out.replaceAllMapped(
      RegExp(
        "(?<![A-Za-z0-9_])((?:token|api_key|access_token|key)\\s*[=:]\\s*)(?:\"[^\"]{4,}\"|'[^']{4,}'|[^\\s&,\"']{4,})",
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
    const sensitive = {'token', 'api_key', 'access_token', 'key'};
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

  List<BrowserConsoleEntry> get entries => List.unmodifiable(_entries);

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
    final want = types.map(normTypeForTest).toSet();
    final q = (urlContains ?? '').trim();
    final filtered = _entries.where((e) {
      if (!want.contains(normTypeForTest(e.type))) return false;
      // R1-A3 无归因可召回：url 为空时回退正文“当前页”后缀匹配，
      // 否则 urlContains=B 下空归因条目永久不可见。
      if (q.isNotEmpty) {
        final u = e.url ?? '';
        if (u.contains(q)) return true;
        if (u.isEmpty && e.message.contains(q)) return true;
        return false;
      }
      return true;
    }).toList();
    if (filtered.isEmpty) return const [];
    final take = n.clamp(1, filtered.length);
    return List.unmodifiable(filtered.sublist(filtered.length - take));
  }

  void clear() => _entries.clear();
}

class BrowserNetworkFailure {
  BrowserNetworkFailure({
    required this.url,
    required this.errorText,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  final String url;
  final String errorText;
  final DateTime time;

  String format() => '$url :: $errorText';
}

/// 网络失败记录：上限 200 条，去重（同 url+error 只保留最新）。
class BrowserNetworkStore {
  BrowserNetworkStore({this.capacity = 200});

  final int capacity;
  // R6-BR3：有序Map去重——此前 List+removeWhere 每推全扫 O(n)，
  // 高频失败页抖动。现 Map 键直达 O(1)，删后重插即搬尾保“最新”语义。
  final Map<String, BrowserNetworkFailure> _map = {};

  List<BrowserNetworkFailure> get items => List.unmodifiable(_map.values);

  static String _key(String url, String errorText) => '$url\u0000$errorText';

  void push(String url, String errorText) {
    // 与 console 同口径：url/error 同样有界，data: URL 不进无界键。
    final rawU = BrowserConsoleStore.redactUrlQuery(url);
    final rawE = BrowserConsoleStore.redactMessage(errorText);
    final u = rawU.length > 512 ? '${rawU.substring(0, 512)}…（已截断）' : rawU;
    final e = rawE.length > 2000
        ? '${rawE.substring(0, 2000)}…（已截断）'
        : rawE;
    final key = _key(u, e);
    _map.remove(key);
    _map[key] = BrowserNetworkFailure(url: u, errorText: e);
    while (_map.length > capacity) {
      _map.remove(_map.keys.first);
    }
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
    final q = (urlContains ?? '').trim();
    final all = _map.values.toList();
    // R11R1-02：空归因可召回——回退存储为空URL时此前按url.contains过滤永久不可见
    // （与console tailWhere正文召回口径分裂）。现空URL条目不过滤（未知归因保守保留），
    // 排查多iframe时不丢证据；调用方仍可用正文/错误文本二次筛选。
    final filtered = q.isEmpty
        ? all
        : all.where((e) => e.url.isEmpty || e.url.contains(q)).toList();
    if (filtered.isEmpty) return const [];
    final take = n.clamp(1, filtered.length);
    return List.unmodifiable(filtered.sublist(filtered.length - take));
  }

  void clear() => _map.clear();
}
