// B6：隧道下载门禁 + 进程启动注入回归。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/mobile_bridge/mobile_tunnel.dart';
import 'package:path/path.dart' as p;

void main() {
  group('下载主机白名单（D2-S3 同口径）', () {
    test('白名单集合覆盖 GitHub/Tailscale 官方源', () {
      expect(mobileTunnelDownloadHosts, contains('github.com'));
      expect(
        mobileTunnelDownloadHosts,
        contains('objects.githubusercontent.com'),
      );
      expect(mobileTunnelDownloadHosts, contains('pkgs.tailscale.com'));
      expect(mobileTunnelDownloadHosts, isNot(contains('evil.example.com')));
    });

    test('非 https / 非白名单主机一律拒', () async {
      final tunnel = MobileTunnel(
        workDir: Directory.systemTemp.path,
        downloader: (url) async => Uint8List.fromList(utf8.encode('x')),
      );
      // 经 ensureBinary 间接触发 _download 前的主机校验：先造一个
      // 本机已有二进制的目录，绕过 findExistingBinary 分支后打私有桩。
      // 此处直接校验 host 白名单函数行为（白名单外抛错）。
      expect(
        () => tunnel.ensureBinaryByUrlForTest(
          'https://evil.example.com/cloudflared',
          expectedSha256: sha256.convert(utf8.encode('x')).toString(),
        ),
        throwsStateError,
      );
      expect(
        () => tunnel.ensureBinaryByUrlForTest(
          'http://github.com/x',
          expectedSha256: sha256.convert(utf8.encode('x')).toString(),
        ),
        throwsStateError,
      );
    });
  });

  group('SHA-256 校验（fail-closed）', () {
    test('缺期望值拒绝；校验不符拒绝；一致放行并落盘', () async {
      final dir = await Directory.systemTemp.createTemp('mobile-tunnel-');
      try {
        final bytes = Uint8List.fromList(utf8.encode('binary-content'));
        final digest = sha256.convert(bytes).toString();
        final tunnel = MobileTunnel(
          workDir: dir.path,
          downloader: (_) async => bytes,
        );
        // 缺期望值 → fail-closed。
        expect(
          () => tunnel.ensureBinaryByUrlForTest(
            'https://github.com/x/cloudflared',
          ),
          throwsStateError,
        );
        // 校验不符 → 拒。
        expect(
          () => tunnel.ensureBinaryByUrlForTest(
            'https://github.com/x/cloudflared',
            expectedSha256: '0' * 64,
          ),
          throwsStateError,
        );
        // 一致 → 放行落盘（bin 名由调用方给定，便于测试）。
        final out = await tunnel.ensureBinaryByUrlForTest(
          'https://github.com/x/cloudflared',
          expectedSha256: digest,
          binName: 'cloudflared-test',
        );
        expect(File(out).existsSync(), isTrue);
        expect(File(out).readAsBytesSync(), bytes);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('二进制规格', () {
    test('cloudflared 规格按平台给出 https GitHub 下载地址', () {
      final tunnel = MobileTunnel(workDir: Directory.systemTemp.path);
      final spec = tunnel.specFor(MobileTunnelKind.cloudflared);
      expect(spec.url, startsWith('https://github.com/cloudflare/cloudflared/'));
      expect(spec.binName, startsWith('cloudflared'));
    });
  });

  group('本机二进制发现', () {
    test('GUI 应用 PATH 不全时回退目录命中 brew 安装位置', () async {
      // 复现：Finder/IDE 启动的 App 不继承 shell PATH，which 找不到
      // /opt/homebrew/bin/cloudflared → 一键外网三个通道全失败。
      // 修复：注入目录 + 内置回退目录（/opt/homebrew/bin 等）在 which 前扫。
      final workDir = await Directory.systemTemp.createTemp('tunnel-cache-');
      final binDir = await Directory.systemTemp.createTemp('tunnel-bins-');
      try {
        // workDir 无缓存 bin（缓存分支 miss），binDir 放假二进制。
        // Windows 上规格 binName 带 .exe 后缀，按平台取规格名。
        final binName = Platform.isWindows ? 'cloudflared.exe' : 'cloudflared';
        final fake = File(p.join(binDir.path, binName));
        await fake.writeAsString('#!/bin/sh\necho fake\n');
        final tunnel = MobileTunnel(
          workDir: workDir.path,
          searchBinDirs: [binDir.path],
        );
        final found = await tunnel.findExistingBinary(
          MobileTunnelKind.cloudflared,
        );
        // 注入目录优先于 PATH which（本机 brew 真二进制即使存在也不干扰）。
        expect(found, fake.path);
      } finally {
        await workDir.delete(recursive: true);
        await binDir.delete(recursive: true);
      }
    });

    test('startTunnel 全失败时 attemptLog 记录逐通道原因', () async {
      // 复现：旧实现 catch(_) 静默，面板只显示"全部失败"无法定位。
      // 修复：attemptLog 逐条记录（binary missing / 未取得地址 / 异常）。
      final workDir = await Directory.systemTemp.createTemp('tunnel-cache-');
      final binDir = await Directory.systemTemp.createTemp('tunnel-bins-');
      try {
        // cloudflared 假二进制：让 _startKind 走到启动器注入点。
        await File(p.join(binDir.path, 'cloudflared')).writeAsString('fake');
        final tunnel = MobileTunnel(
          workDir: workDir.path,
          searchBinDirs: [binDir.path],
          // 假启动器：直接抛（模拟进程启动失败路径）。
          processStarter: (executable, arguments,
              {mode = ProcessStartMode.normal}) async {
            throw StateError('spawn denied');
          },
        );
        final handle = await tunnel.startTunnel(localPort: 18999);
        expect(handle, isNull);
        // cloudflared 通道记录了异常原因（stdin 桩化场景为模式不可用）；
        // tailscale/frps 通道记为未取得地址。
        expect(tunnel.attemptLog, isNotEmpty);
        expect(
          tunnel.attemptLog.firstWhere((e) => e.startsWith('cloudflared')),
          isNotEmpty,
        );
        expect(
          tunnel.attemptLog.where((e) => e.startsWith('tailscale:')),
          isNotEmpty,
        );
        expect(tunnel.attemptLog.where((e) => e.startsWith('frps:')), isNotEmpty);
      } finally {
        await workDir.delete(recursive: true);
        await binDir.delete(recursive: true);
      }
    });
  });

  group('进程模式与 URL 抓取（stdio 可读）', () {
    test('mode 回归：detachedWithStdio 优先，stdio 不可用回落 normal',
        () async {
      // 复现：macOS/Linux 曾用 ProcessStartMode.detached——该模式不连接
      // stdio，读 stderr 抛 "Bad state: stdio is not connected"，一键外网
      // 全通道必败（真机 screenshot 实锤）。修复：首选 detachedWithStdio
      // （脱离进程组 + stdio 可读），stdio 不可用时回落 normal。本锁是
      // 确定性断言（不依赖真实管道）。
      final workDir = await Directory.systemTemp.createTemp('tunnel-cache-');
      final binDir = await Directory.systemTemp.createTemp('tunnel-bins-');
      try {
        await File(
          p.join(
            binDir.path,
            Platform.isWindows ? 'cloudflared.exe' : 'cloudflared',
          ),
        ).writeAsString('fake');
        final captured = <ProcessStartMode>[];
        final tunnel = MobileTunnel(
          workDir: workDir.path,
          searchBinDirs: [binDir.path],
          processStarter:
              (executable, arguments, {mode = ProcessStartMode.normal}) async {
            captured.add(mode);
            // StateError 镜像真机错误类型（实测 detached 读 stdio 抛
            // StateError("Bad state: stdio is not connected")）。
            throw StateError('stub');
          },
        );
        await tunnel.startTunnel(localPort: 18999);
        expect(captured, isNotEmpty);
        if (Platform.isWindows) {
          expect(captured, [ProcessStartMode.normal]);
        } else {
          // 首选 detachedWithStdio；stdio 不可用（StateException）后回落 normal。
          expect(captured, [
            ProcessStartMode.detachedWithStdio,
            ProcessStartMode.normal,
          ]);
        }
      } finally {
        await workDir.delete(recursive: true);
        await binDir.delete(recursive: true);
      }
    });

    test('detachedWithStdio 下真进程能从 stderr 抓取 quick tunnel URL',
        () async {
      // 端到端：真 Process.start + 假 cloudflared 脚本验证 URL 抓取路径。
      // 脚本打完 URL 即退出（部分沙箱桩化"退出才吐字节"，秒退脚本在真实
      // 管道/桩化管道两种环境都能验证；长驻流行为由上面的 mode 锁覆盖）。
      if (Platform.isWindows) return; // #!/bin/sh 脚本无法在 Windows 执行
      final workDir = await Directory.systemTemp.createTemp('tunnel-cache-');
      final binDir = await Directory.systemTemp.createTemp('tunnel-bins-');
      MobileTunnelHandle? handle;
      try {
        final bin = File(p.join(binDir.path, 'cloudflared'));
        await bin.writeAsString(
          '#!/bin/sh\n'
          'case "\$1" in\n'
          '  --version|version|-v) echo "fake-cloudflared 1.0"; exit 0;;\n'
          'esac\n'
          // 真机复现：cloudflared 横幅先打官网链接（带尾逗号噪声），
          // 随后才打专属隧道域名（也带尾逗号）——必须跳过官网链接、
          // 抓到无标点的 trycloudflare 域名。
          'echo "Terms: https://www.cloudflare.com/website-terms/," 1>&2\n'
          'echo "Tunnel: https://fake-tunnel.trycloudflare.com," 1>&2\n'
          'exit 0\n',
        );
        await Process.run('chmod', ['+x', bin.path]);

        final tunnel = MobileTunnel(
          workDir: workDir.path,
          searchBinDirs: [binDir.path],
          // 不注入 processStarter：走真实 Process.start（mode 由被测代码定）。
        );
        handle = await tunnel.startTunnel(localPort: 18998);
        expect(
          handle,
          isNotNull,
          reason: 'attemptLog=${tunnel.attemptLog}',
        );
        // URL 从 stderr 抓到（旧 detached 模式在此处即抛 Bad state）。
        expect(handle!.publicUrl, 'https://fake-tunnel.trycloudflare.com');
        expect(handle.version, contains('fake-cloudflared'));
        expect(handle.binPath, bin.path);
        expect(tunnel.attemptLog.first, startsWith('cloudflared: ok'));
      } finally {
        // 进程可能已自行退出：stop 幂等，防泄漏。
        await handle?.stop();
        await workDir.delete(recursive: true);
        await binDir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
