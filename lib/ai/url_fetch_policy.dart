import 'dart:io';

/// fetch_url 目标门禁：只允许公网 HTTP(S)，DNS 解析后拒绝私网/回环/元数据。
class UrlFetchPolicy {
  UrlFetchPolicy({Set<String>? allowedHosts})
      : allowedHosts = {
          for (final h in allowedHosts ?? const <String>{})
            h.trim().toLowerCase(),
        }..removeWhere((h) => h.isEmpty);

  /// 非空时只允许这些主机（或子域）。空 = 不额外限制公网主机。
  final Set<String> allowedHosts;

  static const maxRedirects = 5;

  String? rejectLiteral(Uri uri) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '仅支持 http(s)：$uri';
    }
    if (uri.host.isEmpty) return 'url 缺少主机：$uri';
    if (uri.userInfo.isNotEmpty) return '拒绝带用户信息的 url：$uri';
    // B15：端口白名单——http(80)/https(443) 之外（22/6379/5432 等）
    // 属探测性连接，默认拒绝。
    final port = uri.port;
    if (port != 0 && port != 80 && port != 443) {
      return '拒绝非标准端口（仅 80/443）：$uri';
    }
    var host = uri.host.toLowerCase();
    // R15R2：尾点 FQDN 归一——`metadata.google.internal.` 与无点同义，
    // 此前精确匹配即被绕过。剥尾点后再比本地域名。
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local') ||
        host.endsWith('.internal') ||
        host.endsWith('.lan') ||
        host == 'metadata.google.internal' ||
        host.endsWith('.metadata.google.internal') ||
        host == 'instance-data.compute.internal' ||
        host.endsWith('.instance-data.compute.internal')) {
      return '拒绝本地域名：$host';
    }
    // 十六进制/八进制/整数 IP 字面量：tryParse 认不出，手动归一化再判。
    final normalizedIp = _normalizeNumericIp(host);
    if (normalizedIp == null && _looksLikeNumericIp(host)) {
      return '拒绝异常 IP 写法：$host';
    }
    final literal = InternetAddress.tryParse(normalizedIp ?? host);
    if (literal != null) {
      final why = rejectAddress(literal);
      if (why != null) return why;
    }
    if (allowedHosts.isNotEmpty && !_hostAllowed(host)) {
      return '主机不在允许列表：$host';
    }
    return null;
  }

  bool _hostAllowed(String host) {
    var h = host.trim().toLowerCase();
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    for (var allowed in allowedHosts) {
      var a = allowed.trim().toLowerCase();
      if (a.endsWith('.')) a = a.substring(0, a.length - 1);
      if (a.isEmpty) continue;
      if (h == a || h.endsWith('.$a')) return true;
    }
    return false;
  }

  /// G-B12：白名单主机判定的公开口径（外部 CDP 端点 attach 校验复用）。
  /// 与 rejectLiteral 的 allowedHosts 语义同源：大小写/尾点归一后，
  /// 命中白名单条目本身或其子域即放行。
  bool hostAllowed(String host) => _hostAllowed(host);

  /// 数字 IP 归一化：0x7f.0.0.1 / 0177.0.0.1 / 2130706433 / 尾点域名。
  /// tryParse 认不出这些写法，手动转点分十进制再判，认不出返回 null。
  /// R1-SSRF疑似数字IP兜底：四段全数字/0x前缀但解析失败（如09无效八进制、
  /// 0xZZ非法十六进制）时_normalizeNumericIp返null，旧口径直接放行待DNS判。
  /// DNS可解析怪写法即旁路。现数字疑似IP解析失败直接拒绝（fail-closed），
  /// 纯字母域名不受影响（每段须数字起首或0x前缀）。
  static bool _looksLikeNumericIp(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty) return false;
    if (RegExp(r'^[0-9]+$').hasMatch(h)) return true;
    if (h.startsWith('0x')) return true;
    if (!h.contains('.')) return false;
    final parts = h.split('.');
    if (parts.length < 2 || parts.length > 4) return false;
    for (final part in parts) {
      final p = part.trim();
      if (p.isEmpty) return false;
      if (p.startsWith('0x')) continue;
      if (RegExp(r'^[0-9]+$').hasMatch(p)) continue;
      return false;
    }
    return true;
  }

  static String? _normalizeNumericIp(String host) {
    var h = host.trim().toLowerCase();
    if (h.isEmpty) return null;
    // 尾点 FQDN：metadata.google.internal. 与无点同义。
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    // 纯整数：32 位 IPv4（如 2130706433 = 127.0.0.1）。
    final asInt = int.tryParse(h);
    if (asInt != null && asInt >= 0 && asInt <= 0xFFFFFFFF) {
      return '${(asInt >> 24) & 0xFF}.${(asInt >> 16) & 0xFF}.${(asInt >> 8) & 0xFF}.${asInt & 0xFF}';
    }
    if (!h.contains('.')) return h == host.toLowerCase() ? null : h;
    final parts = h.split('.');
    if (parts.length != 4) return h == host.toLowerCase() ? null : h;
    final out = <String>[];
    for (final part in parts) {
      int? v;
      final p = part.trim();
      if (p.startsWith('0x') || p.contains(RegExp(r'[a-f]'))) {
        v = int.tryParse(p.startsWith('0x') ? p.substring(2) : p, radix: 16);
      } else if (p.length > 1 && p.startsWith('0')) {
        v = int.tryParse(p, radix: 8);
      } else {
        v = int.tryParse(p);
      }
      if (v == null || v < 0 || v > 255) return null;
      out.add('$v');
    }
    final normalized = out.join('.');
    return normalized;
  }

  String? rejectAddress(InternetAddress addr) {
    final raw = _asIpv4Mapped(addr) ?? addr;
    if (raw.type == InternetAddressType.unix) {
      return '拒绝 unix 套接字目标';
    }
    if (raw.isLoopback) return '拒绝回环地址：${raw.address}';
    if (raw.type == InternetAddressType.IPv4) {
      final b = raw.rawAddress;
      if (b.length == 4 && b[0] == 169 && b[1] == 254 && b[2] == 169 && b[3] == 254) {
        return '拒绝云元数据地址：${raw.address}';
      }
    }
    if (raw.isLinkLocal) return '拒绝链路本地地址：${raw.address}';
    if (raw.isMulticast) return '拒绝组播地址：${raw.address}';
    if (raw.type == InternetAddressType.IPv4) {
      final b = raw.rawAddress;
      if (b.length != 4) return '拒绝异常 IPv4：${raw.address}';
      if (b[0] == 0) return '拒绝保留地址：${raw.address}';
      if (b[0] == 10) return '拒绝私网地址：${raw.address}';
      if (b[0] == 127) return '拒绝回环地址：${raw.address}';
      if (b[0] == 169 && b[1] == 254) return '拒绝链路本地地址：${raw.address}';
      if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) {
        return '拒绝私网地址：${raw.address}';
      }
      if (b[0] == 192 && b[1] == 168) return '拒绝私网地址：${raw.address}';
      if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) {
        return '拒绝共享地址空间：${raw.address}';
      }
      if (b[0] >= 224) return '拒绝保留/组播地址：${raw.address}';
      // A1-8：补齐 IANA 特殊用途注册表（IPv4）保留段——此前这些段
      // rejectAddress 返回 null 被放行，可被用于绕过内网扫描/伪装可信
      // 目标。来源 https://www.iana.org/assignments/iana-ipv4-special-registry/
      // 与 https://datatracker.ietf.org/doc/rfc6890/（特殊用途 IP 地址
      // 注册表含 RFC5735/RFC3849/RFC2544/RFC7534/RFC7450 等条目）。
      if (b[0] == 192 && b[1] == 0 && b[2] == 0) {
        // 192.0.0.0/24 IETF 协议分配（含 192.0.0.9 等知名服务地址）。
        return '拒绝特殊用途地址：${raw.address}';
      }
      if (b[0] == 192 && b[1] == 0 && b[2] == 2) {
        // 192.0.2.0/24 TEST-NET-1（文档示例）。
        return '拒绝保留地址：${raw.address}';
      }
      if (b[0] == 198 && (b[1] == 18 || b[1] == 19)) {
        // 198.18.0.0/15 基准测试（RFC2544）。
        return '拒绝特殊用途地址：${raw.address}';
      }
      if (b[0] == 198 && b[1] == 51 && b[2] == 100) {
        // 198.51.100.0/24 TEST-NET-2（文档示例）。
        return '拒绝保留地址：${raw.address}';
      }
      if (b[0] == 203 && b[1] == 0 && b[2] == 113) {
        // 203.0.113.0/24 TEST-NET-3（文档示例）。
        return '拒绝保留地址：${raw.address}';
      }
      if (b[0] == 192 && b[1] == 88 && b[2] == 99) {
        // 192.88.99.0/24 已废弃 6to4 中继任播（RFC7526 deprecated）。
        return '拒绝特殊用途地址：${raw.address}';
      }
      if (b[0] == 192 && b[1] == 31 && b[2] == 196) {
        // 192.31.196.0/24 AS112 服务（RFC7535）。
        return '拒绝特殊用途地址：${raw.address}';
      }
      if (b[0] == 192 && b[1] == 52 && b[2] == 193) {
        // 192.52.193.0/24 AMT 任播（RFC7450）。
        return '拒绝特殊用途地址：${raw.address}';
      }
      if (b[0] == 192 && b[1] == 175 && b[2] == 48) {
        // 192.175.48.0/24 AS112 直接委派服务（RFC7534）。
        return '拒绝特殊用途地址：${raw.address}';
      }
    } else if (raw.type == InternetAddressType.IPv6) {
      final b = raw.rawAddress;
      if (b.length != 16) return '拒绝异常 IPv6：${raw.address}';
      if (b.every((e) => e == 0)) return '拒绝未指定地址：${raw.address}';
      // A1-8：2002::/16（6to4 封装）——其内可嵌入任意 IPv4 目标，
      // 放行即旁路 IPv4 私网判定（RFC3056）。
      if (b[0] == 0x20 && b[1] == 0x02) {
        return '拒绝特殊用途地址：${raw.address}';
      }
      // A1-8：64:ff9b::/96（NAT64 知名前缀）——把 IPv4 字面量包装成
      // IPv6 即可触达 IPv4 目标，私网/回环复核被绕过（RFC6052）。
      // 前缀 = 00 64 ff 9b + 8 个零字节（共 12 字节），后 4 字节封装 IPv4。
      if (b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b) {
        var midZero = true;
        for (var i = 4; i < 12; i++) {
          if (b[i] != 0) {
            midZero = false;
            break;
          }
        }
        if (midZero) {
          return '拒绝特殊用途地址：${raw.address}';
        }
      }
      // R15R5：AWS IPv6 元数据 fd00:ec2::254——此前仅判 IPv4 169.254.169.254，
      // 双栈 VPC 下 IPv6 元数据漏网。来源
      // https://pipelab.org/learn/preventing-ssrf-in-ai-agents/。
      if (b.length == 16 &&
          b[0] == 0xfd &&
          b[1] == 0x00 &&
          b[2] == 0x0e &&
          b[3] == 0xc2 &&
          b[14] == 0x02 &&
          b[15] == 0x54) {
        var midZero = true;
        for (var i = 4; i < 14; i++) {
          if (b[i] != 0) {
            midZero = false;
            break;
          }
        }
        if (midZero) return '拒绝云元数据地址：${raw.address}';
      }
      // fc00::/7 unique local
      if ((b[0] & 0xfe) == 0xfc) return '拒绝私网地址：${raw.address}';
      // 2001:db8::/32 documentation
      if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) {
        return '拒绝保留地址：${raw.address}';
      }
    }
    return null;
  }

  InternetAddress? _asIpv4Mapped(InternetAddress addr) {
    if (addr.type != InternetAddressType.IPv6) return null;
    final b = addr.rawAddress;
    if (b.length != 16) return null;
    for (var i = 0; i < 10; i++) {
      if (b[i] != 0) return null;
    }
    if (b[10] != 0xff || b[11] != 0xff) return null;
    return InternetAddress.fromRawAddress(
      b.sublist(12),
      type: InternetAddressType.IPv4,
    );
  }

  Future<String?> rejectResolved(Uri uri) async {
    final literal = rejectLiteral(uri);
    if (literal != null) return literal;
    if (InternetAddress.tryParse(uri.host) != null) return null;
    List<InternetAddress> addrs;
    try {
      // R3-DNS超时收敛：无timeout时弱网/劫持DNS可挂死open/fetch整条链。
      // 5s超时失败按可疑拒绝（fail-closed），对照chrome-devtools-mcp网络超时口径。
      addrs = await InternetAddress.lookup(
        uri.host,
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      return 'DNS 解析失败：${uri.host} ($e)';
    }
    if (addrs.isEmpty) return 'DNS 无结果：${uri.host}';
    for (final addr in addrs) {
      final why = rejectAddress(addr);
      if (why != null) return why;
    }
    return null;
  }

  /// R8-1：已校验地址集——返回首轮 lookup 中全部通过私网检查的地址，
  /// connectionFactory 连接时直接复用，不再二次 lookup（DNS 轮转 TOCTOU）。
  /// 任一地址命中私网/回环即返回 null（调用方回退 rejectResolved 拒掉）。
  Future<List<InternetAddress>?> lookupChecked(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) {
      return rejectAddress(literal) == null ? [literal] : null;
    }
    List<InternetAddress> addrs;
    try {
      // R3-同rejectResolved：lookupChecked同样5s超时，超时按null回退拒掉。
      addrs = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 5));
    } catch (_) {
      return null;
    }
    if (addrs.isEmpty) return null;
    for (final addr in addrs) {
      if (rejectAddress(addr) != null) return null;
    }
    return addrs;
  }
}
