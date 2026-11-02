import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'agent_tools.dart';
import 'external_content.dart';

part 'agent_computer_tools_input.dart';

part 'agent_computer_tools_capture.dart';

/// 本机电脑操控工具（computer-use 执行层最小可用版）。
/// 原理对标开源路线（截图+坐标+系统动作，见任务清单 R1）：
/// grounding（坐标理解）由上层模型负责，本文件只做可信执行 —
/// 截图落盘 + 系统键鼠/按键/打开动作经系统命令执行。
/// 安全：调用方（ToolRegistry）必须先走审批，本层不再弹窗，
/// 只做参数复检与系统依赖缺失时的明确失败。
class AgentComputerTools {
  static const toolNames = <String>[
    'computer_screenshot',
    'computer_click',
    'computer_move',
    'computer_drag',
    'computer_scroll',
    'computer_press',
    'computer_type',
    'computer_open',
    // B3：动作补齐（Anthropic computer use 增强动作集口径）——
    // 修饰键按住/释放分离（ctrl+click 多选、shift+click 连选必需）、
    // 渲染等待（等 SPA/动画落定再观测，替代盲 sleep 截屏猜时机）。
    'computer_key',
    'computer_wait',
  ];

  /// 截图目录名单源（测试可见）：与 browser 的 myide-shots 同口径，
  /// 固定单目录复用 + 20 张轮转 + symlink 逃逸校验。
  static const shotsDirNameForTest = 'myide-computer-shots';

  /// 轮内上限与 browser 写通道同口径（20/轮），Registry 侧执行。
  static const turnLimitForTest = 20;

  static bool isToolNameForTest(String name) => toolNames.contains(name);

  /// 按钮合法值（测试可见）。
  static bool isValidButtonForTest(String b) =>
      b == 'left' || b == 'right' || b == 'middle';

  /// 坐标钳制（测试可见）：屏幕像素 0~10000，非法回 null 由调用方拒绝。
  static int? clampCoordForTest(dynamic v) {
    final n = v is num ? v.toInt() : int.tryParse('$v'.trim());
    if (n == null) return null;
    if (n < 0 || n > 10000) return null;
    return n;
  }

  /// S3-1 校验钩子：cmd 元字符检测（Windows computer_open 拒绝口径，
  /// 纯函数便于跨平台单测）。`cmd /c start` 会对参数做命令语法二次解析：
  /// `&` 串命令、`|` 管道、`^` 转义、`%` 变量展开、`!` 延迟变量、
  /// `"` 引号重切、`< >` 重定向。
  static bool containsCmdMetacharsForTest(String target) =>
      RegExp(r'[&|^%!"<>]').hasMatch(target);

  /// S3-2：坐标解析（纯函数，测试可见）——归一化(≤1000)与像素(>1000)双口径。
  /// R-COORD-AMBIG：归一化换算仅在分辨率维度 >1000 时启用——小屏
  /// （≤1000 物理像素/逻辑点）下 (500,400) 像素坐标会被误换算为 (400,240)
  /// 点击错位；维度 ≤1000 时 ≤1000 的值直接按像素原样。
  /// raw>1000：按屏幕像素原样（向后兼容旧 0~10000 口径，仍钳屏幕范围）；
  /// 分辨率未知：维持旧口径（0~10000 像素）。x 轴用 screenW，y 轴用 screenH。
  static int? resolveCoordinate(
    num raw,
    int? screenW,
    int? screenH, {
    bool yAxis = false,
  }) {
    if (raw < 0) return null;
    final dim = (yAxis ? screenH : screenW) ?? 0;
    if (dim > 1000 && raw <= 1000) {
      final v = ((raw * dim) / 1000).round();
      return v < 0 ? 0 : (v > dim ? dim : v);
    }
    if (raw > 10000) return null;
    if (dim > 0 && raw > dim) return dim;
    return raw.toInt();
  }

  /// R-COORD-DPI：JPEG 尺寸解析（SOF0~SOF15 基线/渐进）——macOS
  /// screencapture 输出物理像素图，与 Finder bounds 逻辑点探测口径互斥，
  /// 需按实际图尺寸推 scale 透出给模型。
  static ({int w, int h})? jpegDimensionsForTest(List<int> bytes) {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
    var i = 2;
    while (i + 9 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = bytes[i + 1];
      final isSof = (marker >= 0xC0 && marker <= 0xCF) &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        final h = (bytes[i + 5] << 8) | bytes[i + 6];
        final w = (bytes[i + 7] << 8) | bytes[i + 8];
        if (w > 0 && h > 0) return (w: w, h: h);
        return null;
      }
      if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD9)) {
        i += 2;
        continue;
      }
      final len = (bytes[i + 2] << 8) | bytes[i + 3];
      if (len < 2) return null;
      i += 2 + len;
    }
    return null;
  }

  /// A10 校验钩子：直跑 _run（进程超时终止行为单测用）。
  @visibleForTesting
  Future<({int exitCode, String out, String err})> runForTest(
    String exe,
    List<String> args, {
    Duration timeout = const Duration(seconds: 15),
  }) =>
      _run(exe, args, timeout: timeout);

  /// C4 测试钩子：进程执行桩（recorder 断言 cliclick 动词映射用）——
  /// 非空时全部 _run 走此桩，不触真实系统命令。默认 null 走真实进程。
  @visibleForTesting
  Future<({int exitCode, String out, String err})> Function(
    String exe,
    List<String> args, {
    Duration timeout,
  })? runOverrideForTest;

  /// C4 校验钩子（纯函数）：macOS cliclick 点击动词按 button 映射——
  /// 此前恒 c:（左键），right/middle 在 cliclick 可用时静默执行左键，
  /// 右键菜单/中键开链全错。
  static String cliclickClickVerbForTest(String button) =>
      button == 'right' ? 'rc' : button == 'middle' ? 'mc' : 'c';

  Future<AgentToolResult> execute(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'computer_screenshot':
        return _screenshot(args);
      case 'computer_click':
        return _click(args);
      case 'computer_move':
        return _move(args);
      case 'computer_drag':
        return _drag(args);
      case 'computer_scroll':
        return _scroll(args);
      case 'computer_press':
        return _press(args);
      case 'computer_type':
        return _type(args);
      case 'computer_open':
        return _open(args);
      case 'computer_key':
        return _key(args);
      case 'computer_wait':
        return _wait(args);
      default:
        return AgentToolResult(ok: false, output: '未知电脑操控工具：$name');
    }
  }

  int? _coord(dynamic v, {bool yAxis = false}) {
    final n = clampCoordForTest(v);
    if (n == null) return null;
    // S3-2：分辨率已知时 ≤1000 按归一化换算，>1000 按像素（向后兼容）。
    return resolveCoordinate(n, _screenW, _screenH, yAxis: yAxis);
  }

  // S3-2：屏幕分辨率缓存（实例级，5 分钟失效重取；探测失败保留旧值待下轮再试）。
  int? _screenW;
  int? _screenH;
  DateTime? _screenProbedAt;
  static const _screenProbeTtl = Duration(minutes: 5);

  // B2-9：连续交互计数（Anthropic computer-use「每步截图确认」口径，
  // https://docs.anthropic.com/en/docs/build-with-claude/computer-use）——
  // 动作间无"观测后再动"强制时，模型按失真屏幕状态连续盲操作。连续交互
  // N 次未 computer_screenshot 即在动作输出里提示先观测；screenshot 成功
  // 即重置计数。
  int _interactionsSinceObserve = 0;
  static const _observeNudgeAfter = 5;

  /// B2-9 观测提示纯函数（测试可见）：连续交互达阈值返回提示文案，否则空串。
  static String observeNudgeForTest(int steps) => steps >= _observeNudgeAfter
      ? '（已连续交互 $steps 步未观测，建议先 computer_screenshot 确认屏幕状态再继续）'
      : '';

  /// B2-9 测试钩子：登记一次交互，返回本次是否需要提示（与各动作方法
  /// 成功路径同口径：先计数后取提示）。
  @visibleForTesting
  String recordInteractionForTest() {
    _interactionsSinceObserve++;
    return observeNudgeForTest(_interactionsSinceObserve);
  }

  /// B2-9 测试钩子：观测（screenshot）重置计数。
  @visibleForTesting
  void resetObserveCounterForTest() => _interactionsSinceObserve = 0;

  /// B2-9 测试钩子：当前连续交互计数。
  @visibleForTesting
  int interactionsSinceObserveForTest() => _interactionsSinceObserve;

  /// B2-9 动作成功路径统一调用：计数 +1 并返回观测提示（无提示时空串）。
  String _noteInteraction() {
    _interactionsSinceObserve++;
    return observeNudgeForTest(_interactionsSinceObserve);
  }

  /// B2-9 焦点元素回读解析（测试可见）：osascript stdout → 焦点元素文本
  /// （前 80 字；空/missing value → null 由调用方降级说明）。
  static String? parseFocusedValueForTest(String out) {
    final t = out.trim();
    if (t.isEmpty || t == 'missing value') return null;
    return t.length > 80 ? '${t.substring(0, 80)}…' : t;
  }

  /// B2-9：键入后回读焦点元素值（macOS AXFocusedUIElement，5s 超时）。
  /// 需辅助功能授权；失败/非 macOS 返回 null，调用方降级为提示文案。
  Future<String?> _readFocusedValue() async {
    if (!Platform.isMacOS) return null;
    try {
      final r = await _run(
        'osascript',
        [
          '-e',
          'tell application "System Events" to get value of attribute '
              '"AXFocusedUIElement" of (first application process whose frontmost is true)',
        ],
        timeout: const Duration(seconds: 5),
      );
      if (r.exitCode != 0) return null;
      return parseFocusedValueForTest(r.out);
    } catch (_) {
      return null;
    }
  }

  /// S3-2 校验钩子：当前分辨率缓存（单测断言用）。
  @visibleForTesting
  ({int? w, int? h}) get screenResolutionForTest => (w: _screenW, h: _screenH);

  /// S3-2 校验钩子：osascript bounds 输出解析（"0, 0, 2560, 1440" → 尾两个数）。
  static ({int w, int h})? parseScreenBoundsForTest(String out) =>
      _lastTwoPositiveInts(out);

  /// S3-2 校验钩子：system_profiler "Resolution: 3024 x 1964 Retina" 解析。
  static ({int w, int h})? parseSystemProfilerResolutionForTest(String out) =>
      _firstWxHMatch(RegExp(r'Resolution:\s*(\d+)\s*[xX×]\s*(\d+)'), out);

  /// S3-2 校验钩子：PowerShell "2560x1440" / 通用 WxH 解析。
  static ({int w, int h})? parseWxHResolutionForTest(String out) =>
      _firstWxHMatch(RegExp(r'(\d+)\s*[xX×]\s*(\d+)'), out);

  /// S3-2 校验钩子：xdpyinfo "dimensions: 1920x1080 pixels" 解析。
  static ({int w, int h})? parseXdpyinfoDimensionsForTest(String out) =>
      _firstWxHMatch(RegExp(r'dimensions:\s*(\d+)\s*[xX×]\s*(\d+)'), out);

  /// S3-2 校验钩子：xrandr "current 2560 x 1440" 解析。
  static ({int w, int h})? parseXrandrCurrentForTest(String out) =>
      _firstWxHMatch(RegExp(r'current\s+(\d+)\s*[xX×]\s*(\d+)'), out);

  /// S3-2 校验钩子：wmic 表格输出解析（跳过表头行，取首个含两数的行）。
  static ({int w, int h})? parseWmicResolutionForTest(String out) {
    for (final line in out.split('\n')) {
      if (line.contains('Resolution')) continue;
      final nums = RegExp(r'\d+').allMatches(line).toList();
      if (nums.length >= 2) {
        final w = int.parse(nums[0].group(0)!);
        final h = int.parse(nums[1].group(0)!);
        if (w > 0 && h > 0) return (w: w, h: h);
      }
    }
    return null;
  }

  static ({int w, int h})? _firstWxHMatch(RegExp re, String out) {
    final m = re.firstMatch(out);
    if (m == null) return null;
    final w = int.parse(m.group(1)!);
    final h = int.parse(m.group(2)!);
    if (w <= 0 || h <= 0) return null;
    return (w: w, h: h);
  }

  static ({int w, int h})? _lastTwoPositiveInts(String out) {
    final nums = RegExp(r'\d+')
        .allMatches(out)
        .map((m) => int.parse(m.group(0)!))
        .toList();
    if (nums.length < 2) return null;
    final w = nums[nums.length - 2];
    final h = nums[nums.length - 1];
    if (w <= 0 || h <= 0) return null;
    return (w: w, h: h);
  }

  AgentToolResult _untrusted(String source, String body) {
    final output = wrapUntrustedToolOutput(source: source, body: body);
    return AgentToolResult(
      ok: true,
      untrusted: true,
      source: source,
      output: output,
    );
  }

  /// B3：region 解析（x/y/width/height 须同时给出且合法）——缺任一/越界
  /// 返回 null；全无 region 键返回 null（=全屏）。
  /// C8：坐标口径统一走 resolveCoordinate（归一化≤1000/像素>1000 双口径），
  /// 此前 _regionOf 用 clampCoordForTest 纯像素钳制，与点击的归一化换算
  /// 口径不一致——高分屏下截图按像素截屏幕一点、点击按归一化落另一点。
  /// judgeRegionForTest 暴露 [screenW]/[screenH] 供测试按分辨率验证双口径；
  /// 生产侧 _regionOf 透传实例探测到的分辨率缓存。
  static ({int x, int y, int width, int height})? judgeRegionForTest(
    Map<String, dynamic> args, {
    int? screenW,
    int? screenH,
  }) =>
      _regionResolve(args, screenW, screenH);

  ({int x, int y, int width, int height})? _regionOf(
    Map<String, dynamic> args,
  ) =>
      _regionResolve(args, _screenW, _screenH);

  static ({int x, int y, int width, int height})? _regionResolve(
    Map<String, dynamic> args,
    int? screenW,
    int? screenH,
  ) {
    bool has(String k) => args[k] != null;
    if (!has('x') && !has('y') && !has('width') && !has('height')) {
      return null;
    }
    // C8：先过钳制（0~10000 像素域、非法回 null），再按分辨率双口径解析——
    // ≤1000 归一化换算、>1000 按像素原样，与 computer_click 的 _coord 同源。
    int? at(String k, {bool yAxis = false}) {
      final n = clampCoordForTest(args[k]);
      if (n == null) return null;
      return resolveCoordinate(n, screenW, screenH, yAxis: yAxis);
    }
    final x = at('x');
    final y = at('y', yAxis: true);
    final w = at('width');
    final h = at('height', yAxis: true);
    if (x == null || y == null || w == null || h == null) return null;
    if (w <= 0 || h <= 0) return null;
    return (x: x, y: y, width: w, height: h);
  }

  // —— B3：修饰键按住/释放分离 + 渲染等待 ——

  /// 修饰键集合（大小写不敏感）：按住/释放仅对修饰键做平台级 hold 语义；
  /// 组合键（如 ctrl+shift+a）既有修饰键也有主键。
  static const _modifierKeys = <String>{
    'cmd',
    'command',
    'ctrl',
    'control',
    'alt',
    'option',
    'shift',
    'fn',
    'super',
    'meta',
  };

  /// B3：组合键解析（纯函数，测试可见）——'ctrl+shift+a' →
  /// (mods: [ctrl, shift], main: a)。空串/非法分段（超长/空段）返回 null。
  static ({List<String> mods, String main})? parseKeyComboForTest(String raw) {
    final parts = raw
        .split('+')
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .toList();
    if (parts.isEmpty || parts.length > 4) return null;
    for (final p in parts) {
      if (p.length > 24) return null;
    }
    final mods = parts.where((p) => _modifierKeys.contains(p)).toList();
    final main = parts.where((p) => !_modifierKeys.contains(p)).toList();
    if (main.length > 1) return null; // 主键至多一个
    return (mods: mods, main: main.isEmpty ? '' : main.first);
  }


  AgentToolResult _ok() => AgentToolResult(ok: true, output: 'ok');
}
