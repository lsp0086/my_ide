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
    final host = uri.host.toLowerCase();
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
    for (final allowed in allowedHosts) {
      if (host == allowed || host.endsWith('.$allowed')) return true;
    }
    return false;
  }

  /// 数字 IP 归一化：0x7f.0.0.1 / 0177.0.0.1 / 2130706433 / 尾点域名。
  /// tryParse 认不出这些写法，手动转点分十进制再判，认不出返回 null。
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
    } else if (raw.type == InternetAddressType.IPv6) {
      final b = raw.rawAddress;
      if (b.length != 16) return '拒绝异常 IPv6：${raw.address}';
      if (b.every((e) => e == 0)) return '拒绝未指定地址：${raw.address}';
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
      addrs = await InternetAddress.lookup(uri.host);
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
}
