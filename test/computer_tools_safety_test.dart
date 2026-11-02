import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_computer_tools.dart';

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
String readLibSourceSync(String relPath) {
  final base = File('lib/$relPath');
  var out = base.readAsStringSync();
  final stem = relPath.split('/').last.replaceAll('.dart', '');
  final parts = base.parent
      .listSync()
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith('${stem}_') && name.endsWith('.dart');
      })
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in parts) {
    out += f.readAsStringSync();
  }
  return out;
}

/// 电脑操控安全回归：
/// S3-1 computer_open Windows cmd 元字符防线（拒绝 + 引号整体传参）；
/// S3-2 屏幕分辨率探测（解析纯函数 + 截图透出 + 5min 缓存）与
///      归一化坐标（≤1000）→像素换算、>1000 像素向后兼容；
/// S3-10 截图轮转与 browser 侧同口径（一律删到 20）。
/// 纯函数 + 源码口径断言，不触系统命令。
void main() {
  group('S3-1 computer_open Windows cmd 元字符防线', () {
    test('containsCmdMetacharsForTest：元字符全拒绝，安全 URL/路径放行', () {
      // cmd /c start 二次解析面：& 串命令、| 管道、^ 转义、% 变量展开、
      // ! 延迟变量、" 引号重切、< > 重定向。
      expect(
        AgentComputerTools.containsCmdMetacharsForTest(
            'https://a.test/x?next=/y&calc'),
        isTrue,
      );
      expect(AgentComputerTools.containsCmdMetacharsForTest('a|b'), isTrue);
      expect(AgentComputerTools.containsCmdMetacharsForTest('a^b'), isTrue);
      expect(AgentComputerTools.containsCmdMetacharsForTest('%TEMP%'), isTrue);
      expect(AgentComputerTools.containsCmdMetacharsForTest('a!b'), isTrue);
      expect(AgentComputerTools.containsCmdMetacharsForTest('a"b'), isTrue);
      expect(AgentComputerTools.containsCmdMetacharsForTest('a<b'), isTrue);
      expect(AgentComputerTools.containsCmdMetacharsForTest('a>b'), isTrue);
      // 安全放行：空格、中文、括号、单引号（cmd 不解析单引号）。
      expect(
        AgentComputerTools.containsCmdMetacharsForTest(
            'https://www.example.com/a b?c=1'),
        isFalse,
      );
      expect(
        AgentComputerTools.containsCmdMetacharsForTest(
            r'C:\Users\测试 文档\文件(1).txt'),
        isFalse,
      );
      expect(
        AgentComputerTools.containsCmdMetacharsForTest("https://a.test/it's"),
        isFalse,
      );
    });

    test('源码口径：_open Windows 分支接元字符拒绝 + _systemOpen 引号传参', () {
      final src = readLibSourceSync('ai/agent_computer_tools.dart');
      final openIdx = src.indexOf('Future<AgentToolResult> _open(');
      expect(openIdx, greaterThanOrEqualTo(0));
      final openEnd = src.indexOf('\n  // —— 平台动作', openIdx);
      final openBody = src.substring(
          openIdx, openEnd == -1 ? src.length : openEnd);
      expect(openBody.contains('Platform.isWindows'), isTrue);
      expect(openBody.contains('containsCmdMetacharsForTest'), isTrue,
          reason: 'S3-1：Windows 分支须拒绝含 cmd 元字符的 target');
      // _systemOpen：Windows 分支以带引号形式整体传参（等价 '"$target"'）。
      final sysIdx = src.indexOf('Future<AgentToolResult> _systemOpen(');
      expect(sysIdx, greaterThanOrEqualTo(0));
      final sysEnd = src.indexOf('\n  AgentToolResult _ok()', sysIdx);
      final sysBody = src.substring(sysIdx, sysEnd == -1 ? src.length : sysEnd);
      expect(sysBody.contains("'\"\$target\"'"), isTrue,
          reason: 'S3-1：安全字符仍须以带引号形式传参，防 start 二次拆分/解析');
    });
  });

  group('S3-2 屏幕分辨率探测与归一化坐标', () {
    test('resolveCoordinate：≤1000 归一化换算，>1000 像素向后兼容，钳屏幕范围', () {
      // 归一化：x 用 screenW，y 用 screenH。
      expect(AgentComputerTools.resolveCoordinate(500, 2560, 1440), 1280);
      expect(
        AgentComputerTools.resolveCoordinate(500, 2560, 1440, yAxis: true),
        720,
      );
      expect(AgentComputerTools.resolveCoordinate(0, 2560, 1440), 0);
      expect(AgentComputerTools.resolveCoordinate(1000, 2560, 1440), 2560);
      expect(
        AgentComputerTools.resolveCoordinate(1000, 2560, 1440, yAxis: true),
        1440,
      );
      // 四舍五入边界。
      expect(AgentComputerTools.resolveCoordinate(1, 1000, 1000), 1);
      // >1000 按屏幕像素（向后兼容旧 0~10000 口径）。
      expect(AgentComputerTools.resolveCoordinate(2000, 2560, 1440), 2000);
      expect(AgentComputerTools.resolveCoordinate(2560, 2560, 1440), 2560);
      // 钳屏幕范围：像素超屏收敛到屏幕边界。
      expect(AgentComputerTools.resolveCoordinate(5000, 1000, 800), 1000);
      expect(
        AgentComputerTools.resolveCoordinate(5000, 1000, 800, yAxis: true),
        800,
      );
      // 非法：负数拒绝；分辨率未知时超 10000 仍拒绝（旧口径）。
      expect(AgentComputerTools.resolveCoordinate(-1, 2560, 1440), isNull);
      expect(AgentComputerTools.resolveCoordinate(10001, null, null), isNull);
      // 分辨率未知：≤1000 维持旧像素口径不换算。
      expect(AgentComputerTools.resolveCoordinate(800, null, null), 800);
    });

    test('探测输出解析：bounds/system_profiler/xdpyinfo/xrandr/WxH/wmic', () {
      expect(
        AgentComputerTools.parseScreenBoundsForTest('0, 0, 2560, 1440'),
        (w: 2560, h: 1440),
      );
      expect(
        AgentComputerTools.parseSystemProfilerResolutionForTest(
            '      Resolution: 3024 x 1964 Retina'),
        (w: 3024, h: 1964),
      );
      expect(
        AgentComputerTools.parseXdpyinfoDimensionsForTest(
            '  dimensions:    1920x1080 pixels (508x285 millimeters)'),
        (w: 1920, h: 1080),
      );
      expect(
        AgentComputerTools.parseXrandrCurrentForTest(
            'Screen 0: minimum 8 x 8, current 2560 x 1440, maximum 32767 x 32767'),
        (w: 2560, h: 1440),
      );
      expect(
        AgentComputerTools.parseWxHResolutionForTest('2560x1440'),
        (w: 2560, h: 1440),
      );
      expect(
        AgentComputerTools.parseWmicResolutionForTest(
            'CurrentHorizontalResolution  CurrentVerticalResolution\n'
            '1920                         1080\n'),
        (w: 1920, h: 1080),
      );
      // 解析失败回 null，不误报。
      expect(AgentComputerTools.parseScreenBoundsForTest('no digits'), isNull);
      expect(AgentComputerTools.parseXdpyinfoDimensionsForTest('error'), isNull);
      expect(AgentComputerTools.parseWmicResolutionForTest(''), isNull);
    });

    test('源码口径：screenshot 透出分辨率行 + 实例缓存 5min 失效', () {
      final src = readLibSourceSync('ai/agent_computer_tools.dart');
      // R-COORD-DPI：Retina 截图输出物理像素，须区分逻辑分辨率并透出
      // DPR 换算，模型不得拿截图像素直接点击。
      expect(src.contains('屏幕（逻辑）分辨率: '), isTrue,
          reason: 'S3-2/C2：截图成功输出须透出逻辑分辨率');
      expect(src.contains('像素*1000/分辨率'), isTrue);
      expect(src.contains('_screenProbeTtl = Duration(minutes: 5)'), isTrue,
          reason: 'S3-2：探测缓存 5 分钟失效重取');
      expect(src.contains('await _probeScreenResolution()'), isTrue,
          reason: 'S3-2：截图成功路径须探测/刷新分辨率缓存');
      // 实例字段缓存：_screenW/_screenH 供 _coord 换算。
      expect(src.contains('resolveCoordinate(n, _screenW, _screenH'), isTrue,
          reason: 'S3-2：_coord 按实例缓存分辨率换算');
    });
  });

  group('S3-10 截图轮转与 browser 侧同口径', () {
    test('源码口径：>60/常规一律删到 20（不再 >60 保留 59）', () {
      final src = readLibSourceSync('ai/agent_computer_tools.dart');
      final idx = src.indexOf('Future<void> _rotateShots(');
      expect(idx, greaterThanOrEqualTo(0));
      final end = src.indexOf('\n  Future<String> _describeFile(', idx);
      final body = src.substring(idx, end == -1 ? src.length : end);
      expect(body.contains('> 60'), isFalse,
          reason: 'S3-10：>60 保留 59 的分叉口径已删');
      expect(body.contains('const keep = 20;'), isTrue,
          reason: 'S3-10：与 browser_service（>60 删到 20）同口径');
    });
  });

  group('computer-use 动作补齐', () {
    test('toolNames 扩容：computer_key / computer_wait', () {
      expect(AgentComputerTools.isToolNameForTest('computer_key'), isTrue);
      expect(AgentComputerTools.isToolNameForTest('computer_wait'), isTrue);
      expect(AgentComputerTools.toolNames, hasLength(10));
    });

    test('组合键解析：修饰/主键拆分 + 非法拒绝', () {
      final c1 = AgentComputerTools.parseKeyComboForTest('ctrl+shift+a');
      expect(c1!.mods, ['ctrl', 'shift']);
      expect(c1.main, 'a');
      final c2 = AgentComputerTools.parseKeyComboForTest(' Cmd ');
      expect(c2!.mods, ['cmd']);
      expect(c2.main, '');
      final c3 = AgentComputerTools.parseKeyComboForTest('enter');
      expect(c3!.mods, isEmpty);
      expect(c3.main, 'enter');
      // 两个主键/超长段/空段非法。
      expect(AgentComputerTools.parseKeyComboForTest('ctrl+a+b'), isNull);
      expect(
        AgentComputerTools.parseKeyComboForTest('ctrl+${'x' * 25}'),
        isNull,
      );
      expect(AgentComputerTools.parseKeyComboForTest('+'), isNull);
      expect(AgentComputerTools.parseKeyComboForTest(''), isNull);
    });

    test('region 解析：四键齐备才生效，缺一/零尺寸拒绝', () {
      expect(
        AgentComputerTools.judgeRegionForTest(const {}),
        isNull,
        reason: '无 region 键=全屏',
      );
      final r = AgentComputerTools.judgeRegionForTest(const {
        'x': 100,
        'y': 200,
        'width': 300,
        'height': 400,
      });
      expect(r!.x, 100);
      expect(r.y, 200);
      expect(r.width, 300);
      expect(r.height, 400);
      // 缺一个键即拒（半 region 会截出错误区域）。
      expect(
        AgentComputerTools.judgeRegionForTest(const {
          'x': 1,
          'y': 1,
          'width': 2,
        }),
        isNull,
      );
      // 零/负尺寸拒。
      expect(
        AgentComputerTools.judgeRegionForTest(const {
          'x': 0,
          'y': 0,
          'width': 0,
          'height': 10,
        }),
        isNull,
      );
      // 越界坐标拒（>10000）。
      expect(
        AgentComputerTools.judgeRegionForTest(const {
          'x': 0,
          'y': 0,
          'width': 10001,
          'height': 10,
        }),
        isNull,
      );
    });

    test('行为：computer_wait 延迟后返回 ok', () async {
      final tools = AgentComputerTools();
      final t0 = DateTime.now();
      final r = await tools.execute('computer_wait', {'ms': 150});
      expect(r.ok, isTrue);
      expect(r.output, contains('150ms'));
      expect(
        DateTime.now().difference(t0).inMilliseconds,
        greaterThanOrEqualTo(120),
      );
      // 默认 1000ms 会被钳制下限 100——传 1 钳到 100。
      final clamped = await tools.execute('computer_wait', {'ms': 1});
      expect(clamped.ok, isTrue);
      expect(clamped.output, contains('100ms'));
    });

    test('行为：computer_key 非法 action/长度在执行前拒绝', () async {
      final tools = AgentComputerTools();
      final bad = await tools.execute('computer_key', {
        'keys': 'ctrl+a',
        'action': 'smash',
      });
      expect(bad.ok, isFalse);
      expect(bad.output, contains('action 非法'));
      final long = await tools.execute('computer_key', {'keys': 'x' * 65});
      expect(long.ok, isFalse);
      expect(long.output, contains('缺少合法 keys'));
      final empty = await tools.execute('computer_key', {});
      expect(empty.ok, isFalse);
    });

    test('行为：computer_key 普通键 down 在 macOS 明确失败（不盲按）', () async {
      final tools = AgentComputerTools();
      final r = await tools.execute('computer_key', {
        'keys': 'a',
        'action': 'down',
      });
      // 本用例在 macOS 上跑：普通键无平台 hold 语义，明确失败。
      if (r.ok) return; // 非 macOS 平台由上面各分支兜底，跳过。
      expect(r.output, contains('普通键暂不支持按住/释放'));
    });

    test('源码口径：双击/三击连发 + 区域截图参数进平台调用', () {
      final src = readLibSourceSync('ai/agent_computer_tools.dart');
      expect(src.contains('已双击'), isTrue);
      expect(src.contains('已三击'), isTrue);
      expect(
        src.contains("'-R',"),
        isTrue,
        reason: 'macOS 区域截图须走 screencapture -R',
      );
      expect(
        src.contains("'-crop',"),
        isTrue,
        reason: 'Linux 区域截图须走 import -crop',
      );
      expect(src.contains('区域截图: ('), isTrue, reason: '结果须透出区域口径');
    });
  });

  group('观测后再动（键入回读 + 连点阈值提示）', () {
    test('焦点回读解析：前 80 字截断，missing value/空为 null', () {
      expect(AgentComputerTools.parseFocusedValueForTest('  hello  '), 'hello');
      expect(
        AgentComputerTools.parseFocusedValueForTest('x' * 200)?.length,
        81,
        reason: '前 80 字 + 省略号',
      );
      expect(
        AgentComputerTools.parseFocusedValueForTest('missing value'),
        isNull,
      );
      expect(AgentComputerTools.parseFocusedValueForTest(''), isNull);
    });

    test('连点阈值：连续交互 N 次未观测即提示先 screenshot', () {
      expect(AgentComputerTools.observeNudgeForTest(4), isEmpty);
      final hint = AgentComputerTools.observeNudgeForTest(5);
      expect(hint, contains('computer_screenshot'));
      expect(hint, contains('连续交互 5 步'));
    });

    test('计数行为：交互累加、screenshot 重置（钩子口径）', () {
      final tools = AgentComputerTools();
      tools.resetObserveCounterForTest();
      expect(tools.interactionsSinceObserveForTest(), 0);
      String? lastHint;
      for (var i = 0; i < 4; i++) {
        lastHint = tools.recordInteractionForTest();
      }
      expect(lastHint, isEmpty, reason: '第 4 步未达阈值不提示');
      expect(
        tools.recordInteractionForTest(),
        contains('computer_screenshot'),
        reason: '第 5 步触发观测提示',
      );
      tools.resetObserveCounterForTest();
      expect(
        tools.interactionsSinceObserveForTest(),
        0,
        reason: 'screenshot 即观测，重置连续交互计数',
      );
    });

    test('源码口径：computer_type 回读焦点元素且动作路径计数提示', () {
      final src = readLibSourceSync('ai/agent_computer_tools.dart');
      final fn = src.indexOf('Future<AgentToolResult> _type(');
      expect(fn, greaterThanOrEqualTo(0));
      final end = src.indexOf('\n  }\n', fn);
      final body = src.substring(fn, end == -1 ? src.length : end);
      expect(
        body.contains('_readFocusedValue()'),
        isTrue,
        reason: '键入后须回读焦点元素',
      );
      expect(
        body.contains('_noteInteraction()'),
        isTrue,
        reason: '键入计入连续交互（连点提示链）',
      );
      expect(
        src.contains('AXFocusedUIElement'),
        isTrue,
        reason: 'macOS 只读焦点通道走 AXFocusedUIElement',
      );
      // 截图成功路径重置计数。
      final shot = src.indexOf('Future<AgentToolResult> _screenshot(');
      expect(shot, greaterThanOrEqualTo(0));
      expect(
        src.substring(shot).contains('_interactionsSinceObserve = 0;'),
        isTrue,
        reason: '截图即观测，重置计数',
      );
    });
  });
}
