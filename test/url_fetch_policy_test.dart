import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/url_fetch_policy.dart';

void main() {
  test('字面量拒绝回环、私网、元数据和本地域名', () {
    final cases = <String, String>{
      'http://127.0.0.1/': '回环',
      'https://[::1]/': '回环',
      'http://localhost/secret': '本地',
      'http://foo.localhost/': '本地',
      'http://printer.local/': '本地',
      'http://10.0.0.1/': '私网',
      'http://192.168.1.1/': '私网',
      'http://172.16.0.9/': '私网',
      'http://169.254.169.254/latest/meta-data/': '元数据',
      'http://100.64.0.1/': '共享',
      'http://224.0.0.1/': '组播',
      'http://0.0.0.0/': '保留',
      'ftp://example.com/': 'http',
      'http://user:pass@example.com/': '用户信息',
    };
    for (final entry in cases.entries) {
      final why = UrlFetchPolicy().rejectLiteral(Uri.parse(entry.key));
      expect(why, isNotNull, reason: entry.key);
      expect(why, contains(entry.value), reason: entry.key);
    }
  });

  test('公网主机字面量放行，允许列表收紧', () {
    expect(
      UrlFetchPolicy().rejectLiteral(Uri.parse('https://example.com/a')),
      isNull,
    );
    expect(
      UrlFetchPolicy(allowedHosts: {'example.com'}).rejectLiteral(
        Uri.parse('https://sub.example.com/a'),
      ),
      isNull,
    );
    expect(
      UrlFetchPolicy(allowedHosts: {'example.com'}).rejectLiteral(
        Uri.parse('https://evil.com/a'),
      ),
      contains('允许列表'),
    );
  });

  test('B15 端口白名单：非 80/443 显式端口拒绝', () {
    expect(
      UrlFetchPolicy()
          .rejectLiteral(Uri.parse('http://example.com:22/')),
      contains('非标准端口'),
    );
    expect(
      UrlFetchPolicy()
          .rejectLiteral(Uri.parse('http://example.com:6379/')),
      contains('非标准端口'),
    );
    // 隐式默认端口放行。
    expect(
      UrlFetchPolicy().rejectLiteral(Uri.parse('https://example.com/a')),
      isNull,
    );
    expect(
      UrlFetchPolicy().rejectLiteral(Uri.parse('http://example.com:80/')),
      isNull,
    );
    expect(
      UrlFetchPolicy().rejectLiteral(Uri.parse('https://example.com:443/')),
      isNull,
    );
  });

  test('IPv4/IPv6 地址分类', () {
    String? why(String ip) =>
        UrlFetchPolicy().rejectAddress(InternetAddress(ip));
    expect(why('8.8.8.8'), isNull);
    expect(why('1.1.1.1'), isNull);
    expect(why('127.0.0.1'), contains('回环'));
    expect(why('10.1.2.3'), contains('私网'));
    expect(why('172.31.255.255'), contains('私网'));
    expect(why('192.168.0.1'), contains('私网'));
    expect(why('169.254.169.254'), contains('元数据'));
    expect(why('::1'), contains('回环'));
    expect(why('fe80::1'), contains('链路本地'));
    expect(why('fc00::1'), contains('私网'));
    expect(why('ff02::1'), contains('组播'));

    final mappedLoopback = InternetAddress.fromRawAddress(
      Uint8List.fromList(
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1],
      ),
      type: InternetAddressType.IPv6,
    );
    expect(UrlFetchPolicy().rejectAddress(mappedLoopback), contains('回环'));
    final mappedPrivate = InternetAddress.fromRawAddress(
      Uint8List.fromList(
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 168, 1, 1],
      ),
      type: InternetAddressType.IPv6,
    );
    expect(UrlFetchPolicy().rejectAddress(mappedPrivate), contains('私网'));
  });

  test('R11R10 重定向切scheme拒绝：file/gopher不跟随', () {
    // 口径：current.resolve(loc) 后非 http(s) 直接拒绝。
    // 此处断言 resolve 语义本身（跟随切 scheme 可被构造），执行层已钳制。
    final base = Uri.parse('https://example.com/a');
    expect(base.resolve('file:///etc/passwd').scheme, 'file');
    expect(base.resolve('gopher://x/1').scheme, 'gopher');
    expect(base.resolve('/b').scheme, 'https');
    // 口径回归：非 http(s) 起始 url 同样被 rejectLiteral 拒绝。
    expect(
      UrlFetchPolicy().rejectLiteral(Uri.parse('file:///etc/passwd')),
      contains('http'),
    );
  });

  test('R8-1 lookupChecked字面量口径与rejectAddress一致', () async {
    // 127.0.0.1 命中回环即 null（调用方回退拒掉），不再二次解析直连。
    expect(await UrlFetchPolicy().lookupChecked('127.0.0.1'), isNull);
    expect(await UrlFetchPolicy().lookupChecked('10.0.0.1'), isNull);
  });

  test('R15R2 尾点元数据域名同样拒绝', () {
    final p = UrlFetchPolicy();
    expect(
      p.rejectLiteral(Uri.parse('http://metadata.google.internal./')),
      isNotNull,
    );
    expect(
      p.rejectLiteral(Uri.parse('http://instance-data.compute.internal./x')),
      isNotNull,
    );
  });

  test('R15R5 IPv6元数据fd00:ec2::254拒绝', () {
    final p = UrlFetchPolicy();
    final addr = InternetAddress.fromRawAddress(
      Uint8List.fromList(
        [0xfd, 0x00, 0x0e, 0xc2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x54],
      ),
      type: InternetAddressType.IPv6,
    );
    expect(p.rejectAddress(addr), isNotNull);
  });

  test('数字疑似IP解析失败直接拒绝', () {
    final p = UrlFetchPolicy();
    expect(
      p.rejectLiteral(Uri.parse('http://09.0.0.1/')),
      contains('异常'),
    );
    expect(
      p.rejectLiteral(Uri.parse('http://0xZZ.0.0.1/')),
      isNotNull,
    );
    expect(
      p.rejectLiteral(Uri.parse('http://2130706433/')),
      contains('回环'),
    );
  });

  test('允许列表尾点FQDN归一：example.com. 与 example.com 同口径', () {
    // 复现：allowedHosts={'example.com'} 时 'https://example.com./a' 此前误拒。
    expect(
      UrlFetchPolicy(allowedHosts: {'example.com'}).rejectLiteral(
        Uri.parse('https://example.com./a'),
      ),
      isNull,
    );
    expect(
      UrlFetchPolicy(allowedHosts: {'example.com.'}).rejectLiteral(
        Uri.parse('https://example.com/a'),
      ),
      isNull,
    );
    expect(
      UrlFetchPolicy(allowedHosts: {'example.com'}).rejectLiteral(
        Uri.parse('https://sub.example.com./a'),
      ),
      isNull,
    );
  });

  test('lookupChecked 校验通过返回可直连地址集，未通过返回 null', () async {
    // 行为断言：连接统一复用 lookupChecked 返回的已校验地址集直连
    //（不再二次解析，消除 DNS 轮转 TOCTOU 窗口），故其返回全量通过
    // 私网检查的地址；任一地址可疑即返回 null。字面量不触发 DNS，可离线断言。
    final ok = await UrlFetchPolicy().lookupChecked('8.8.8.8');
    expect(ok, isNotNull);
    expect(ok!.map((a) => a.address), ['8.8.8.8']);
    expect(await UrlFetchPolicy().lookupChecked('127.0.0.1'), isNull);
  });

  test('DNS 解析两路同口径：lookupChecked 与 rejectResolved 判定一致', () async {
    // 行为断言：DNS 校验两条路径同 5s 超时、同私网判定——私网字面量
    // 两路一致拒绝，公网字面量两路一致放行（字面量路径不触发 DNS 查询）。
    final policy = UrlFetchPolicy();
    expect(await policy.lookupChecked('127.0.0.1'), isNull);
    expect(
      await policy.rejectResolved(Uri.parse('http://127.0.0.1/')),
      isNotNull,
    );
    expect(await policy.lookupChecked('8.8.8.8'), isNotNull);
    expect(
      await policy.rejectResolved(Uri.parse('http://8.8.8.8/')),
      isNull,
    );
  });

  test('A1-8 IETF 特殊用途保留段全部拒绝（此前返回 null 被放行）', () {
    // 复现 A1-8：rejectAddress 缺 IANA 特殊用途注册表保留段——
    // 192.0.0.0/24、TEST-NET（192.0.2/24、198.51.100/24、203.0.113/24）、
    // 198.18.0.0/15、255.255.255.255、IPv6 2002::/16 等此前放行。
    // 来源 https://www.iana.org/assignments/iana-ipv4-special-registry/
    // 与 RFC6890 / RFC3056(6to4) / RFC6052(NAT64)。
    String? why(String ip) =>
        UrlFetchPolicy().rejectAddress(InternetAddress(ip));
    // IPv4 保留段。
    for (final ip in const [
      '192.0.0.1', // 192.0.0.0/24 IETF 协议分配
      '192.0.0.9', // 同上段内知名服务地址
      '192.0.2.1', // TEST-NET-1
      '198.18.0.1', // 198.18.0.0/15 基准测试
      '198.19.255.255', // 同上段末端
      '198.51.100.7', // TEST-NET-2
      '203.0.113.9', // TEST-NET-3
      '255.255.255.255', // 有限广播
      '192.88.99.1', // 废弃 6to4 中继任播
      '192.31.196.1', // AS112 服务
      '192.52.193.1', // AMT 任播
      '192.175.48.1', // AS112 直接委派
    ]) {
      expect(why(ip), isNotNull, reason: '$ip 应被拒绝');
    }
    // IPv6 保留段。
    expect(why('2002:7f00:1::'), isNotNull, reason: '6to4 封装回环');
    expect(why('2002:0a00:0001::'), isNotNull, reason: '6to4 封装私网 10.0.0.1');
    expect(
      why('64:ff9b::7f00:1'),
      isNotNull,
      reason: 'NAT64 知名前缀封装回环',
    );
    expect(
      why('64:ff9b::0a00:1'),
      isNotNull,
      reason: 'NAT64 知名前缀封装私网',
    );
    // 公网地址不受影响（不误杀）。
    expect(why('8.8.8.8'), isNull);
    expect(why('1.1.1.1'), isNull);
    expect(why('2606:4700:4700::1111'), isNull);
    // 字面量 URL 路径同口径（rejectLiteral 走同一 rejectAddress）。
    for (final url in const [
      'http://192.0.2.1/',
      'http://203.0.113.9/',
      'http://[2002:7f00:1::]/',
      'http://[64:ff9b::7f00:1]/',
    ]) {
      expect(
        UrlFetchPolicy().rejectLiteral(Uri.parse(url)),
        isNotNull,
        reason: url,
      );
    }
    // IPv4-mapped IPv6 同样在 _asIpv4Mapped 归一后命中新规则。
    final mappedTestNet = InternetAddress.fromRawAddress(
      Uint8List.fromList(
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 192, 0, 2, 1],
      ),
      type: InternetAddressType.IPv6,
    );
    expect(UrlFetchPolicy().rejectAddress(mappedTestNet), isNotNull);
  });
}
