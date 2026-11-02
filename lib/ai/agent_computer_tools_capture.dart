part of 'agent_computer_tools.dart';

/// 截屏与进程域：屏幕分辨率探测、系统命令执行、截图目录轮转、截图落盘。
/// 原为 AgentComputerTools 私有实例方法，抽出后仍为库私有 extension。
extension _AgentComputerToolsCaptureExt on AgentComputerTools {
  /// S3-2：屏幕分辨率探测（按平台系统命令，结果缓存 5 分钟）。
  Future<void> _probeScreenResolution() async {
    final cached = _screenProbedAt;
    if (_screenW != null &&
        _screenH != null &&
        cached != null &&
        DateTime.now().difference(cached) < AgentComputerTools._screenProbeTtl) {
      return;
    }
    ({int w, int h})? probed;
    try {
      if (Platform.isMacOS) {
        // osascript Finder 桌面 bounds 最快；失败退 system_profiler。
        var r = await _run(
          'osascript',
          ['-e', 'tell application "Finder" to get bounds of window of desktop'],
          timeout: const Duration(seconds: 5),
        );
        var size = AgentComputerTools.parseScreenBoundsForTest(r.out);
        if (size == null) {
          r = await _run(
            'system_profiler',
            ['SPDisplaysDataType'],
            timeout: const Duration(seconds: 8),
          );
          size = AgentComputerTools.parseSystemProfilerResolutionForTest(r.out);
        }
        probed = size;
      } else if (Platform.isWindows) {
        // PowerShell Screen.Bounds（wmic 在新 Win11 已移除，仅作 fallback）。
        var r = await _run(
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Add-Type -AssemblyName System.Windows.Forms; '
                '\$b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds; '
                '"\$(\$b.Width)x\$(\$b.Height)"',
          ],
          timeout: const Duration(seconds: 8),
        );
        var size = AgentComputerTools.parseWxHResolutionForTest(r.out);
        if (size == null) {
          r = await _run(
            'wmic',
            [
              'path',
              'Win32_VideoController',
              'get',
              'CurrentHorizontalResolution,CurrentVerticalResolution',
            ],
            timeout: const Duration(seconds: 8),
          );
          size = AgentComputerTools.parseWmicResolutionForTest(r.out);
        }
        probed = size;
      } else if (Platform.isLinux) {
        var r = await _run('xdpyinfo', [], timeout: const Duration(seconds: 5));
        var size = AgentComputerTools.parseXdpyinfoDimensionsForTest(r.out);
        if (size == null) {
          // Wayland/精简发行版常缺 xdpyinfo，退 xrandr --current。
          r = await _run(
            'xrandr',
            ['--current'],
            timeout: const Duration(seconds: 5),
          );
          size = AgentComputerTools.parseXrandrCurrentForTest(r.out);
        }
        probed = size;
      }
    } catch (_) {}
    if (probed != null && probed.w > 0 && probed.h > 0) {
      _screenW = probed.w;
      _screenH = probed.h;
      _screenProbedAt = DateTime.now();
    }
  }

  Future<({int exitCode, String out, String err})> _run(
    String exe,
    List<String> args, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    // C4：测试桩优先——recorder 断言命令序列不触真实系统命令。
    final override = runOverrideForTest;
    if (override != null) {
      return override(exe, args, timeout: timeout);
    }
    Process? proc;
    try {
      // A10：Process.start+kill——此前 Process.run 超时只丢 Future 不终止
      // 底层进程，挂死的 screencapture/osascript/xdotool 常驻累积，每次
      // 重试再起一个（同文件 _keyType 已用此正确范式）。超时 kill 后返 124。
      proc = await Process.start(exe, args);
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      final outDone = proc.stdout
          .transform(const SystemEncoding().decoder)
          .fold<StringBuffer>(
            stdoutBuf,
            (b, s) => b..write(s),
          );
      final errDone = proc.stderr
          .transform(const SystemEncoding().decoder)
          .fold<StringBuffer>(
            stderrBuf,
            (b, s) => b..write(s),
          );
      final code = await proc.exitCode.timeout(timeout, onTimeout: () {
        try {
          proc?.kill(ProcessSignal.sigkill);
        } catch (_) {}
        return 124;
      });
      // 收尾读尽管道，防子进程因管道满阻塞退出后缓冲残留。
      String outText = '';
      String errText = '';
      try {
        final parts = await Future.wait([outDone, errDone]).timeout(
          const Duration(seconds: 2),
          onTimeout: () => <StringBuffer>[stdoutBuf, stderrBuf],
        );
        outText = parts[0].toString().trim();
        errText = parts[1].toString().trim();
      } catch (_) {
        outText = stdoutBuf.toString().trim();
        errText = stderrBuf.toString().trim();
      }
      return (
        exitCode: code,
        out: outText,
        err: code == 124 && errText.isEmpty
            ? '执行超时（${timeout.inSeconds}s）已熔断'
            : errText,
      );
    } catch (e) {
      return (exitCode: 127, out: '', err: '$e');
    } finally {
      // 双保险：任何异常路径都不留活进程。
      try {
        proc?.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  Future<Directory> _shotsDir() async {
    final dir = Directory(
      p.join(Directory.systemTemp.path, AgentComputerTools.shotsDirNameForTest),
    );
    try {
      final t = FileSystemEntity.typeSync(dir.path, followLinks: false);
      if (t == FileSystemEntityType.link ||
          (t != FileSystemEntityType.notFound &&
              t != FileSystemEntityType.directory)) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
    return dir.create(recursive: true);
  }

  Future<void> _rotateShots(Directory dir) async {
    try {
      final entities = await dir.list().toList();
      final files = entities
          .whereType<File>()
          .where(
            (f) =>
                (f.path.endsWith('.jpg') || f.path.endsWith('.png')) &&
                p.basename(f.path).startsWith('shot-'),
          )
          .toList();
      if (files.length <= 20) return;
      // A14：统一按 mtime 升序删最旧——此前超 60 张走文件名排序，
      // shot- 时间戳名在跨目录残留/时钟回拨时“最旧”判断失真，可能误删新图。
      final mtimes = <String, DateTime>{};
      for (final f in files) {
        try {
          mtimes[f.path] = (await f.stat()).modified;
        } catch (_) {
          mtimes[f.path] = DateTime.fromMillisecondsSinceEpoch(0);
        }
      }
      files.sort(
        (a, b) => (mtimes[a.path] ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(
              mtimes[b.path] ?? DateTime.fromMillisecondsSinceEpoch(0),
            ),
      );
      // S3-10：与 browser 侧截图轮转同口径——一律删到 20（此前 >60 时保留
      // 59，与 browser_service >60 删到 20 不一致）。
      const keep = 20;
      while (files.length > keep) {
        final victim = files.removeAt(0);
        try {
          await victim.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<String> _describeFile(String path) async {
    try {
      final len = await File(path).length();
      return '约 $len 字节。';
    } catch (_) {
      return '';
    }
  }

  /// 全屏截图：macOS screencapture / Linux 常见三件套 / Windows PowerShell。
  /// 成功落盘到 tmp/myide-computer-shots，失败返回明确缺失提示。
  /// B3：region 可选区域截图（Windows 365 MCP crop 口径）——x/y/width/height
  /// 均给且合法时只截该区域（错误恢复期放大局部细节，不必全屏再裁）。
  Future<AgentToolResult> _screenshot(Map<String, dynamic> args) async {
    late final Directory dir;
    try {
      dir = await _shotsDir();
    } catch (e) {
      return AgentToolResult(ok: false, output: '截图目录不可写：$e');
    }
    // B3：region 解析（纯函数 judgeRegionForTest 同口径；C8 起与点击
    // 共用 resolveCoordinate 双口径——≤1000 归一化、>1000 像素）。
    final region = _regionOf(args);
    if (args.containsKey('x') ||
        args.containsKey('y') ||
        args.containsKey('width') ||
        args.containsKey('height')) {
      if (region == null) {
        return AgentToolResult(
          ok: false,
          output: 'computer_screenshot region 非法：x/y/width/height 须同时给出且 0<width,height≤10000、x/y≥0（坐标口径同点击：≤1000 归一化或屏幕像素）',
        );
      }
    }
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final file = File(p.join(dir.path, 'shot-$stamp.jpg'));
    if (Platform.isMacOS) {
      final extra = region == null
          ? <String>['-x', '-t', 'jpg', file.path]
          : <String>[
              '-x',
              '-t',
              'jpg',
              '-R',
              '${region.x},${region.y},${region.width},${region.height}',
              file.path,
            ];
      final r = await _run('screencapture', extra);
      if (r.exitCode != 0 || !await file.exists()) {
        return AgentToolResult(
          ok: false,
          output: '本机截图失败（screencapture）：${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}',
        );
      }
    } else if (Platform.isLinux) {
      // 依次尝试 gnome-screenshot / import(ImageMagick) / scrot。
      var ok = false;
      String lastErr = '';
      var r = region == null
          ? await _run('gnome-screenshot', ['-f', file.path])
          : await _run('gnome-screenshot', [
              '-f',
              file.path,
              // gnome-screenshot 无区域参数：区域走 import 裁剪（见下）。
            ]);
      if (r.exitCode == 0 && await file.exists()) {
        ok = true;
      } else {
        lastErr = r.err.isEmpty ? 'gnome-screenshot exit=${r.exitCode}' : r.err;
      }
      if (!ok) {
        // import：区域裁剪为 WxH+X+Y，全屏为 -window root。
        r = await _run('import', [
          if (region == null) '-window',
          if (region == null) 'root',
          if (region != null) '-crop',
          if (region != null) '${region.width}x${region.height}+${region.x}+${region.y}',
          file.path,
        ]);
        if (r.exitCode == 0 && await file.exists()) {
          ok = true;
        } else {
          lastErr = r.err.isEmpty ? 'import exit=${r.exitCode}' : r.err;
        }
      }
      if (!ok) {
        r = await _run('scrot', [file.path]);
        if (r.exitCode == 0 && await file.exists()) {
          ok = true;
        } else {
          lastErr = r.err.isEmpty ? 'scrot exit=${r.exitCode}' : r.err;
        }
      }
      if (!ok) {
        return AgentToolResult(
          ok: false,
          output:
              '本机截图失败：Linux 需 gnome-screenshot / ImageMagick(import) / scrot 任一（$lastErr）',
        );
      }
    } else if (Platform.isWindows) {
      // PowerShell：主屏截图存 JPEG，需 System.Windows.Forms + Drawing。
      const ps =
          r"Add-Type -AssemblyName System.Windows.Forms,System.Drawing; $b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $bmp=New-Object System.Drawing.Bitmap($b.Width,$b.Height); $g=[System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size); $bmp.Save($env:MYIDE_SHOT,'System.Drawing.Imaging.ImageFormat::Jpeg');";
      final r = await _run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          ps.replaceAll(
            r'$env:MYIDE_SHOT',
            "'${file.path.replaceAll("'", "''")}'",
          ),
        ],
        timeout: const Duration(seconds: 20),
      );
      if (r.exitCode != 0 || !await file.exists()) {
        return AgentToolResult(
          ok: false,
          output:
              '本机截图失败（PowerShell）：${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}',
        );
      }
      // B3：Windows 侧无原生区域参数——全屏落盘后按 region 裁剪
      // （DrawImage 需 Drawing2D.InterpolationMode，避免拉伸失真）。
      if (region != null) {
        final cropped = File('${file.path}.crop.jpg');
        final cropPs =
            "Add-Type -AssemblyName System.Drawing; "
            "\$src=[System.Drawing.Image]::FromFile('${file.path.replaceAll("'", "''")}'); "
            "\$dst=New-Object System.Drawing.Bitmap(${region.width},${region.height}); "
            "\$g=[System.Drawing.Graphics]::FromImage(\$dst); "
            "\$g.InterpolationMode=[System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic; "
            "\$g.DrawImage(\$src,(New-Object System.Drawing.Rectangle(0,0,${region.width},${region.height})),(New-Object System.Drawing.Rectangle(${region.x},${region.y},${region.width},${region.height})),[System.Drawing.GraphicsUnit]::Pixel); "
            "\$dst.Save('${cropped.path.replaceAll("'", "''")}','System.Drawing.Imaging.ImageFormat::Jpeg'); "
            "\$src.Dispose(); \$dst.Dispose();";
        final cr = await _run(
          'powershell',
          ['-NoProfile', '-NonInteractive', '-Command', cropPs],
          timeout: const Duration(seconds: 20),
        );
        if (cr.exitCode != 0) {
          return AgentToolResult(
            ok: false,
            output: '区域裁剪失败（PowerShell）：${cr.err.isEmpty ? 'exit=${cr.exitCode}' : cr.err}',
          );
        }
        // 裁剪产物即最终截图：替换原文件（原全屏图轮转名不变）。
        try {
          await file.delete();
          await cropped.rename(file.path);
        } catch (_) {}
      }
    } else {
      return AgentToolResult(ok: false, output: '当前平台不支持本机截图');
    }
    await _rotateShots(dir);
    // S3-2：截图成功即探测/刷新分辨率缓存，并把分辨率透出给模型——
    // 归一化坐标(0~1000)可按「像素*1000/分辨率」反推，不再盲猜屏幕像素。
    await _probeScreenResolution();
    final desc = await _describeFile(file.path);
    // R-COORD-DPI：读截图实际像素尺寸——macOS screencapture 输出物理像素
    // （Retina 为逻辑 2x），与逻辑点点击坐标口径差 scale，必须透出换算关系，
    // 否则模型按"截图像素=点击像素"推断在 Retina 上系统性偏 2 倍。
    String resLine = '';
    try {
      final head = await file.readAsBytes();
      final shot = AgentComputerTools.jpegDimensionsForTest(
        head.length > 256 * 1024 ? head.sublist(0, 256 * 1024) : head,
      );
      if (_screenW != null && _screenH != null) {
        resLine = '屏幕（逻辑）分辨率: $_screenW x $_screenH\n';
        if (shot != null) {
          final scaleX = shot.w / _screenW!;
          final scaleY = shot.h / _screenH!;
          final rounded = (scaleX + scaleY) / 2;
          final scaleStr = rounded >= 1.5
              ? rounded.round().toString()
              : rounded.toStringAsFixed(2);
          resLine +=
              '截图物理像素: ${shot.w} x ${shot.h}（DPR≈$scaleStr）\n';
          if (rounded >= 1.2) {
            resLine +=
                '⚠️ 高分屏：截图像素 ÷ $scaleStr ≈ 点击坐标（逻辑点），不要直接用截图像素点击。\n';
          }
        }
      } else if (shot != null) {
        resLine = '截图像素: ${shot.w} x ${shot.h}（屏幕逻辑分辨率未知，点击按像素口径）\n';
      }
    } catch (_) {}
    // B2-9：截图即观测——重置连续交互计数（"观测后再动"闭环的观测侧）。
    _interactionsSinceObserve = 0;
    final regionLine = region == null
        ? ''
        : '区域截图: (${region.x},${region.y}) ${region.width}x${region.height}（屏幕像素）\n';
    return _untrusted(
      'computer_screenshot',
      '本机截图已存 ${file.path}，$desc'
      '$regionLine'
      '$resLine'
      '下一步如需点击请先用视觉模型在截图上定位，坐标按上方换算说明处理后再调 computer_click（支持 0-1000 归一化或屏幕像素）。',
    );
  }
}
