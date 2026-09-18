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
}
