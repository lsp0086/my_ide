part of 'agent_computer_tools.dart';

/// 输入/按键域：鼠标点击/移动/拖拽/滚轮/按下、按键组合与平台键名映射、
/// 键入与系统打开。原为 AgentComputerTools 私有实例方法，抽出后仍为库私有 extension。
extension _AgentComputerToolsInputExt on AgentComputerTools {
  /// 平台鼠标点击。macOS 走 cliclick（若安装）否则 AppleScript；
  /// Linux 走 xdotool；Windows 走 PowerShell mouse_event。
  /// B3：times=2/3 双击/三击（同坐标连发，间隔 60ms——低于系统双击
  /// 判定阈值的一半，避免被合并为一次双击语义漂移）。
  Future<AgentToolResult> _click(Map<String, dynamic> args) async {
    final x = _coord(args['x']);
    final y = _coord(args['y'], yAxis: true);
    if (x == null || y == null) {
      return AgentToolResult(ok: false, output: 'computer_click 缺少合法 x/y（0~10000 屏幕像素）');
    }
    final button = '${args['button'] ?? 'left'}'.trim().toLowerCase();
    if (!AgentComputerTools.isValidButtonForTest(button)) {
      return AgentToolResult(ok: false, output: 'computer_click button 非法（left/right/middle）');
    }
    var times = 1;
    final tv = args['times'];
    if (tv is num) {
      times = tv.toInt().clamp(1, 3);
    } else if (tv != null) {
      times = (int.tryParse('$tv'.trim()) ?? 1).clamp(1, 3);
    }
    for (var i = 0; i < times; i++) {
      final r = await _mouseClick(x, y, button);
      if (!r.ok) return r;
      if (i < times - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
    final label = times == 1 ? '已点击' : (times == 2 ? '已双击' : '已三击');
    return _untrusted('computer_click', '$label ($x,$y) [$button]。${_noteInteraction()}');
  }

  Future<AgentToolResult> _move(Map<String, dynamic> args) async {
    final x = _coord(args['x']);
    final y = _coord(args['y'], yAxis: true);
    if (x == null || y == null) {
      return AgentToolResult(ok: false, output: 'computer_move 缺少合法 x/y（0~10000 屏幕像素）');
    }
    final r = await _mouseMove(x, y);
    if (!r.ok) return r;
    return _untrusted('computer_move', '鼠标已移到 ($x,$y)。${_noteInteraction()}');
  }

  Future<AgentToolResult> _drag(Map<String, dynamic> args) async {
    int? numAt(String k, {bool yAxis = false}) => _coord(args[k], yAxis: yAxis);
    final x1 = numAt('x1') ?? numAt('fromX') ?? _coord(args['x']);
    final y1 =
        numAt('y1', yAxis: true) ?? numAt('fromY', yAxis: true) ?? _coord(args['y'], yAxis: true);
    final x2 = numAt('x2') ?? numAt('toX');
    final y2 = numAt('y2', yAxis: true) ?? numAt('toY', yAxis: true);
    if (x1 == null || y1 == null || x2 == null || y2 == null) {
      return AgentToolResult(
        ok: false,
        output: 'computer_drag 缺少合法起点/终点（x1/y1/x2/y2，0~10000）',
      );
    }
    final r = await _mouseDrag(x1, y1, x2, y2);
    if (!r.ok) return r;
    return _untrusted('computer_drag', '已拖拽 ($x1,$y1) → ($x2,$y2)。${_noteInteraction()}');
  }

  Future<AgentToolResult> _scroll(Map<String, dynamic> args) async {
    final raw = args['direction'] ?? args['dir'] ?? 'down';
    final direction = '$raw'.trim().toLowerCase();
    const allowed = {'up', 'down', 'left', 'right'};
    if (!allowed.contains(direction)) {
      return AgentToolResult(ok: false, output: 'computer_scroll direction 非法（up/down/left/right）');
    }
    var amount = 3;
    final v = args['amount'];
    if (v is num) {
      amount = v.toInt().clamp(1, 20);
    } else if (v != null) {
      amount = (int.tryParse('$v'.trim()) ?? 3).clamp(1, 20);
    }
    final x = args['x'] == null ? null : _coord(args['x']);
    final y = args['y'] == null ? null : _coord(args['y'], yAxis: true);
    if ((args['x'] != null && x == null) || (args['y'] != null && y == null)) {
      return AgentToolResult(ok: false, output: 'computer_scroll x/y 非法（0~10000）');
    }
    final r = await _mouseScroll(direction, amount, x, y);
    if (!r.ok) return r;
    return _untrusted(
      'computer_scroll',
      '已滚动 $direction ×$amount${x == null ? '' : ' @($x,$y)'}。${_noteInteraction()}',
    );
  }

  Future<AgentToolResult> _press(Map<String, dynamic> args) async {
    final key = '${args['key'] ?? ''}'.trim();
    if (key.isEmpty || key.length > 64) {
      return AgentToolResult(ok: false, output: 'computer_press 缺少合法 key（≤64 字符，如 Enter/Escape/Tab/F5）');
    }
    if (!RegExp(r'^[A-Za-z0-9 _+\-.,;:/\\\[\]()]+$').hasMatch(key) &&
        !_knownSpecialKey(key)) {
      return AgentToolResult(ok: false, output: 'computer_press key 含非法字符，已拒绝');
    }
    final r = await _keyPress(key);
    if (!r.ok) return r;
    return _untrusted('computer_press', '已按键 $key。${_noteInteraction()}');
  }

  bool _knownSpecialKey(String key) {
    const known = {
      'enter',
      'escape',
      'esc',
      'tab',
      'space',
      'backspace',
      'delete',
      'up',
      'down',
      'left',
      'right',
      'home',
      'end',
      'pageup',
      'pagedown',
      'f1',
      'f2',
      'f3',
      'f4',
      'f5',
      'f6',
      'f7',
      'f8',
      'f9',
      'f10',
      'f11',
      'f12',
    };
    return known.contains(key.trim().toLowerCase());
  }

  /// A13：SendKeys 元字符转义——SendKeys 把 `+^%~(){}[]` 当修饰符/分组/
  /// 特殊键语法（MS 文档口径），裸传 `+` 会被当 Shift、`~` 被当 Enter、
  /// `()` 被当分组。单字符键按官方转义包裹：`{`→`{{}`、`}`→`{}}`、
  /// `+`→`{ADD}`、`^`→`{^}`、`%`→`{%}`、`~`→`{~}`、`(`→`{(}`、`)`→`{)}`。
  /// 命名键（Enter/F5 等纯字母数字）不受影响，原样通过。
  String _escapeSendKeys(String k) {
    const escapes = <String, String>{
      '{': '{{}',
      '}': '{}}',
      '+': '{ADD}',
      '^': '{^}',
      '%': '{%}',
      '~': '{~}',
      '(': '{(}',
      ')': '{)}',
    };
    final sb = StringBuffer();
    for (final ch in k.split('')) {
      sb.write(escapes[ch] ?? ch);
    }
    return sb.toString();
  }

  Future<AgentToolResult> _type(Map<String, dynamic> args) async {
    final text = '${args['text'] ?? ''}';
    if (text.isEmpty || text.length > 4000) {
      return AgentToolResult(ok: false, output: 'computer_type 缺少合法 text（1~4000 字符）');
    }
    final r = await _keyType(text);
    if (!r.ok) return r;
    final shown = text.length > 120 ? '${text.substring(0, 120)}…（已截断）' : text;
    // B2-9：键入后回读焦点元素值（前 80 字）——"观测后再动"的键入确认，
    // 模型无需额外观测即可判断输入是否落进目标框。无只读焦点通道
    // （非 macOS/未授权）时降级为提示，不谎报已确认。
    final back = await _readFocusedValue();
    final note = back == null
        ? '（焦点回读不可用：需 macOS 辅助功能授权，或当前平台无只读焦点通道，请 computer_screenshot 确认）'
        : '（焦点元素回读：$back）';
    return _untrusted('computer_type', '已键入 ${text.length} 字符：$shown$note${_noteInteraction()}');
  }

  Future<AgentToolResult> _open(Map<String, dynamic> args) async {
    final target = '${args['target'] ?? args['path'] ?? args['url'] ?? ''}'.trim();
    if (target.isEmpty || target.length > 2048) {
      return AgentToolResult(ok: false, output: 'computer_open 缺少合法 target（路径或 http(s) URL，≤2048）');
    }
    final lower = target.toLowerCase();
    final isUrl = lower.startsWith('http://') || lower.startsWith('https://');
    if (!isUrl) {
      // 路径模式：拒绝 shell 元字符与穿越，存在性由系统打开结果判定。
      if (target.contains('\n') ||
          target.contains('\r') ||
          target.contains('\x00')) {
        return AgentToolResult(ok: false, output: 'computer_open target 含非法字符，已拒绝');
      }
    }
    // S3-1：Windows `cmd /c start` 会把参数当命令语法二次解析（Dart 在
    // Windows 拼参数不加引号），target 含 cmd 元字符即可拼接注入命令。
    // Windows 上一律拒绝；macOS/Linux 走 argv 直传无此攻击面。
    if (Platform.isWindows && AgentComputerTools.containsCmdMetacharsForTest(target)) {
      return AgentToolResult(
        ok: false,
        output: 'computer_open target 包含命令元字符（& | ^ % ! " < >），已拒绝',
      );
    }
    final r = await _systemOpen(target);
    if (!r.ok) return r;
    return _untrusted('computer_open', '已打开 $target。');
  }

  /// B3：按键 down/up 分离 + hold。action=tap（默认，等价 computer_press
  /// 的组合键扩展）/down（按住不释放）/up（释放）/hold（按下→等 holdMs→释放）。
  /// keys 支持组合（ctrl+shift+a）。macOS 修饰键走 cliclick kd:/ku:（无则明确
  /// 失败）；Linux 走 xdotool keydown/keyup/key；Windows 走 keybd_event
  /// P/Invoke（tap 回落 SendKeys）。
  Future<AgentToolResult> _key(Map<String, dynamic> args) async {
    final raw = '${args['keys'] ?? args['key'] ?? ''}'.trim();
    if (raw.isEmpty || raw.length > 64) {
      return AgentToolResult(
        ok: false,
        output: 'computer_key 缺少合法 keys（≤64 字符，支持组合如 ctrl+shift+a）',
      );
    }
    final combo = AgentComputerTools.parseKeyComboForTest(raw);
    if (combo == null) {
      return AgentToolResult(ok: false, output: 'computer_key keys 解析失败：$raw');
    }
    if (combo.main.isEmpty && combo.mods.isEmpty) {
      return AgentToolResult(ok: false, output: 'computer_key keys 为空');
    }
    final action = '${args['action'] ?? 'tap'}'.trim().toLowerCase();
    const actions = {'tap', 'down', 'up', 'hold'};
    if (!actions.contains(action)) {
      return AgentToolResult(
        ok: false,
        output: 'computer_key action 非法（tap/down/up/hold）',
      );
    }
    var holdMs = 500;
    final hv = args['holdMs'];
    if (hv is num) {
      holdMs = hv.toInt().clamp(50, 60000);
    } else if (hv != null) {
      holdMs = (int.tryParse('$hv'.trim()) ?? 500).clamp(50, 60000);
    }
    AgentToolResult fail(String msg) => AgentToolResult(ok: false, output: msg);
    if (Platform.isMacOS) {
      if (combo.mods.isEmpty) {
        // 单主键无修饰：tap 复用 _keyPress；down/up 无平台 hold 语义。
        if (action == 'tap') return _keyPress(combo.main);
        return fail('macOS 普通键暂不支持按住/释放（仅修饰键可用 cliclick 按住）：${combo.main}');
      }
      Future<AgentToolResult> cli(String verb, String key) async {
        final r = await _run('cliclick', ['$verb:$key']);
        if (r.exitCode == 0) return _ok();
        return fail(
          'macOS ${verb == 'kd' ? '按住' : '释放'}失败：需安装 cliclick（brew install cliclick）（exit=${r.exitCode}）',
        );
      }

      Future<AgentToolResult> releaseAll() async {
        for (final m in combo.mods.reversed) {
          final r = await cli('ku', _macModifierName(m));
          if (!r.ok) return r;
        }
        return _ok();
      }

      switch (action) {
        case 'down':
          for (final m in combo.mods) {
            final r = await cli('kd', _macModifierName(m));
            if (!r.ok) return r;
          }
          return _untrusted('computer_key', '已按住 $raw。');
        case 'up':
          final r = await releaseAll();
          if (!r.ok) return r;
          return _untrusted('computer_key', '已释放 $raw。');
        case 'hold':
          for (final m in combo.mods) {
            final r = await cli('kd', _macModifierName(m));
            if (!r.ok) return r;
          }
          await Future<void>.delayed(Duration(milliseconds: holdMs));
          final r = await releaseAll();
          if (!r.ok) return r;
          return _untrusted('computer_key', '已按住 $raw ${holdMs}ms 后释放。');
        default:
          // tap + 有修饰键：先按住修饰键→主键点击/按键→释放。
          for (final m in combo.mods) {
            final r = await cli('kd', _macModifierName(m));
            if (!r.ok) return r;
          }
          try {
            if (combo.main.isEmpty) {
              // 纯修饰键 tap=短按后立即释放。
              await Future<void>.delayed(const Duration(milliseconds: 60));
            } else {
              final code = _macKeyCode(combo.main);
              if (code == null) {
                return fail('macOS 暂不支持按键 ${combo.main}（无 key code 映射）');
              }
              final r = await _run('osascript', [
                '-e',
                'tell application "System Events" to key code $code',
              ]);
              if (r.exitCode != 0) {
                return fail('macOS 组合键主键失败：需辅助功能授权（exit=${r.exitCode}）');
              }
            }
          } finally {
            await releaseAll();
          }
          return _untrusted('computer_key', '已触发组合键 $raw。');
      }
    }
    if (Platform.isLinux) {
      final mods = combo.mods.map(_linuxModifierName).toList();
      final all = [...mods, if (combo.main.isNotEmpty) _linuxKeyName(combo.main)];
      final seq = all.join('+');
      switch (action) {
        case 'down':
          for (final m in mods) {
            final r = await _run('xdotool', ['keydown', m]);
            if (r.exitCode != 0) {
              return fail('Linux 按住失败：需安装 xdotool（exit=${r.exitCode}）');
            }
          }
          return _untrusted('computer_key', '已按住 $raw。');
        case 'up':
          for (final m in mods.reversed) {
            final r = await _run('xdotool', ['keyup', m]);
            if (r.exitCode != 0) {
              return fail('Linux 释放失败：需安装 xdotool（exit=${r.exitCode}）');
            }
          }
          return _untrusted('computer_key', '已释放 $raw。');
        case 'hold':
          for (final m in mods) {
            final r = await _run('xdotool', ['keydown', m]);
            if (r.exitCode != 0) {
              return fail('Linux 按住失败：需安装 xdotool（exit=${r.exitCode}）');
            }
          }
          await Future<void>.delayed(Duration(milliseconds: holdMs));
          for (final m in mods.reversed) {
            final r = await _run('xdotool', ['keyup', m]);
            if (r.exitCode != 0) {
              return fail('Linux 释放失败：需安装 xdotool（exit=${r.exitCode}）');
            }
          }
          return _untrusted('computer_key', '已按住 $raw ${holdMs}ms 后释放。');
        default:
          final r = await _run('xdotool', ['key', seq]);
          if (r.exitCode != 0) {
            return fail('Linux 组合键失败：需安装 xdotool（exit=${r.exitCode}）');
          }
          return _untrusted('computer_key', '已触发组合键 $raw。');
      }
    }
    if (Platform.isWindows) {
      // A13 同口径：tap 走 SendKeys（修饰键前缀）；down/up 走 keybd_event
      // P/Invoke（仅修饰键有 VK 映射，普通键 hold 明确失败不盲按）。
      if (action == 'tap') {
        if (combo.mods.isEmpty) return _keyPress(combo.main);
        final prefix = combo.mods.map(_winSendPrefix).join();
        final body = _escapeSendKeys(combo.main).replaceAll('"', '""');
        final r = await _run('powershell', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait("$prefix$body");',
        ]);
        if (r.exitCode != 0) {
          return fail('Windows 组合键失败（exit=${r.exitCode}）');
        }
        return _untrusted('computer_key', '已触发组合键 $raw。');
      }
      if (combo.main.isNotEmpty) {
        return fail('Windows 普通键暂不支持按住/释放（仅修饰键可用 keybd_event）：${combo.main}');
      }
      final vk = combo.mods.map(_winVk).toList();
      if (vk.any((e) => e == null)) {
        return fail('Windows 修饰键无 VK 映射：$raw');
      }
      const script = r'''
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MyIdeKbd {
  [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
  public static void Key(byte vk, bool up) { keybd_event(vk, 0, up ? 2u : 0u, UIntPtr.Zero); }
}
"@;
''';
      Future<AgentToolResult> keyEvent(bool up) async {
        final vks = up ? vk.reversed.toList() : vk.toList();
        for (final code in vks) {
          final r = await _run('powershell', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            '$script [MyIdeKbd]::Key($code, ${up ? 'true' : 'false'});',
          ]);
          if (r.exitCode != 0) return fail('Windows 按键事件失败（exit=${r.exitCode}）');
        }
        return _ok();
      }

      if (action == 'down') {
        final r = await keyEvent(false);
        if (!r.ok) return r;
        return _untrusted('computer_key', '已按住 $raw。');
      }
      if (action == 'up') {
        final r = await keyEvent(true);
        if (!r.ok) return r;
        return _untrusted('computer_key', '已释放 $raw。');
      }
      final down = await keyEvent(false);
      if (!down.ok) return down;
      await Future<void>.delayed(Duration(milliseconds: holdMs));
      final up = await keyEvent(true);
      if (!up.ok) return up;
      return _untrusted('computer_key', '已按住 $raw ${holdMs}ms 后释放。');
    }
    return AgentToolResult(ok: false, output: '当前平台不支持按键按住/释放');
  }

  String _macModifierName(String m) {
    switch (m) {
      case 'command':
        return 'cmd';
      case 'control':
        return 'ctrl';
      case 'option':
        return 'alt';
      default:
        return m;
    }
  }

  String _linuxModifierName(String m) {
    switch (m) {
      case 'command':
      case 'cmd':
      case 'super':
      case 'meta':
        return 'super';
      case 'control':
        return 'ctrl';
      case 'option':
        return 'alt';
      default:
        return m;
    }
  }

  String _linuxKeyName(String k) {
    switch (k) {
      case 'esc':
        return 'Escape';
      case 'enter':
        return 'Return';
      case 'space':
        return 'space';
      default:
        return k;
    }
  }

  String _winSendPrefix(String m) {
    switch (m) {
      case 'shift':
        return '+';
      case 'control':
      case 'ctrl':
        return '^';
      case 'alt':
      case 'option':
        return '%';
      case 'command':
      case 'cmd':
      case 'super':
      case 'meta':
        return '^(%{F13})'; // Win 键无 SendKeys 直接前缀，映射到 F13 兜底
      default:
        return '';
    }
  }

  int? _winVk(String m) {
    switch (m) {
      case 'shift':
        return 0x10;
      case 'control':
      case 'ctrl':
        return 0x11;
      case 'alt':
      case 'option':
        return 0x12;
      default:
        return null;
    }
  }

  /// B3：渲染等待——等 SPA 懒加载/动画落定后再观测（替代盲截图猜时机）。
  /// 纯延迟无系统依赖，100~30000ms，默认 1000。
  Future<AgentToolResult> _wait(Map<String, dynamic> args) async {
    var ms = 1000;
    final v = args['ms'];
    if (v is num) {
      ms = v.toInt().clamp(100, 30000);
    } else if (v != null) {
      ms = (int.tryParse('$v'.trim()) ?? 1000).clamp(100, 30000);
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
    return AgentToolResult(ok: true, output: '已等待 ${ms}ms。');
  }

  // —— 平台动作（系统命令 Best-effort，缺依赖即明确失败） ——

  Future<AgentToolResult> _mouseClick(int x, int y, String button) async {
    if (Platform.isMacOS) {
      // 优先 cliclick（精确左右键），无则 AppleScript 左键兜底。
      // C4：cliclick 动词按 button 映射——此前恒 c:（左键），right/middle
      // 在 cliclick 可用时静默执行左键，右键菜单/中键开链全错。
      final verb = AgentComputerTools.cliclickClickVerbForTest(button);
      var r = await _run('cliclick', ['$verb:$x,$y']);
      if (r.exitCode == 0) return _ok();
      if (button != 'left') {
        return AgentToolResult(
          ok: false,
          output:
              'macOS 右键/中键需安装 cliclick（brew install cliclick）后重试；当前 cliclick 不可用（exit=${r.exitCode}）',
        );
      }
      r = await _run('osascript', [
        '-e',
        'tell application "System Events" to click at {$x, $y}',
      ]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output:
            'macOS 点击失败：需在“系统设置→隐私与安全性→辅助功能”授权本应用，且 cliclick 未安装（${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}）',
      );
    }
    if (Platform.isLinux) {
      final code = button == 'right'
          ? '3'
          : button == 'middle'
              ? '2'
              : '1';
      final r = await _run('xdotool', [
        'mousemove',
        '$x',
        '$y',
        'click',
        code,
      ]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: 'Linux 点击失败：需安装 xdotool（${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}）',
      );
    }
    if (Platform.isWindows) {
      final flags = button == 'right'
          ? '0x0008,0x0010'
          : button == 'middle'
              ? '0x0020,0x0040'
              : '0x0002,0x0004';
      final r = await _run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Add-Type -MemberDefinition "[DllImport(\\"user32.dll\\")]public static extern bool SetCursorPos(int X,int Y);[DllImport(\\"user32.dll\\")]public static extern void mouse_event(int d,int dx,int dy,int b,int e);" -Name M -Namespace W; [W.M]::SetCursorPos($x,$y); [W.M]::mouse_event(${flags.split(',')[0]},0,0,0,0); [W.M]::mouse_event(${flags.split(',')[1]},0,0,0,0);',
      ]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output:
            'Windows 点击失败（PowerShell）：${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}',
      );
    }
    return AgentToolResult(ok: false, output: '当前平台不支持鼠标点击');
  }

  Future<AgentToolResult> _mouseMove(int x, int y) async {
    if (Platform.isMacOS) {
      // R4-4：AppleScript 无移鼠标语义（此前 no-op set 调用结果被丢弃），
      // cliclick 缺失即明确失败，不伪装成功。
      final r = await _run('cliclick', ['m:$x,$y']);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: 'macOS 移鼠标需 cliclick（brew install cliclick），当前不可用（exit=${r.exitCode}）',
      );
    }
    if (Platform.isLinux) {
      final r = await _run('xdotool', ['mousemove', '$x', '$y']);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: 'Linux 移鼠标失败：需安装 xdotool（${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}）',
      );
    }
    if (Platform.isWindows) {
      final r = await _run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Add-Type -MemberDefinition "[DllImport(\\"user32.dll\\")]public static extern bool SetCursorPos(int X,int Y);" -Name M -Namespace W; [W.M]::SetCursorPos($x,$y);',
      ]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output:
            'Windows 移鼠标失败（PowerShell）：${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}',
      );
    }
    return AgentToolResult(ok: false, output: '当前平台不支持鼠标移动');
  }

  Future<AgentToolResult> _mouseDrag(int x1, int y1, int x2, int y2) async {
    if (Platform.isMacOS) {
      final r = await _run('cliclick', ['dd:$x1,$y1', 'dm:$x2,$y2', 'du:$x2,$y2']);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: 'macOS 拖拽需 cliclick（brew install cliclick），当前不可用（exit=${r.exitCode}）',
      );
    }
    if (Platform.isLinux) {
      final r = await _run('xdotool', [
        'mousemove',
        '$x1',
        '$y1',
        'mousedown',
        '1',
        'mousemove',
        '$x2',
        '$y2',
        'mouseup',
        '1',
      ]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: 'Linux 拖拽失败：需安装 xdotool（${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}）',
      );
    }
    if (Platform.isWindows) {
      return AgentToolResult(ok: false, output: 'Windows 拖拽暂不支持，请用点击分步操作');
    }
    return AgentToolResult(ok: false, output: '当前平台不支持拖拽');
  }

  Future<AgentToolResult> _mouseScroll(
    String direction,
    int amount,
    int? x,
    int? y,
  ) async {
    if (Platform.isMacOS) {
      // cliclick w:+/-N 为纵向滚轮；横向用 AppleScript 尽力而为。
      if (direction == 'left' || direction == 'right') {
        return AgentToolResult(ok: false, output: 'macOS 横向滚动暂不支持，请用纵向滚动');
      }
      final delta = direction == 'up' ? amount : -amount;
      final r = await _run('cliclick', ['w:$delta']);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: 'macOS 滚动需 cliclick（brew install cliclick），当前不可用（exit=${r.exitCode}）',
      );
    }
    if (Platform.isLinux) {
      // xdotool click 4/5/6/7 = 上/下/左/右。
      final code = direction == 'up'
          ? '4'
          : direction == 'down'
              ? '5'
              : direction == 'left'
                  ? '6'
                  : '7';
      for (var i = 0; i < amount; i++) {
        final r = await _run('xdotool', ['click', code]);
        if (r.exitCode != 0) {
          return AgentToolResult(
            ok: false,
            output: 'Linux 滚动失败：需安装 xdotool（${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}）',
          );
        }
      }
      return _ok();
    }
    if (Platform.isWindows) {
      final delta = (direction == 'up' ? 120 : -120) * amount;
      final r = await _run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Add-Type -MemberDefinition "[DllImport(\\"user32.dll\\")]public static extern void mouse_event(int d,int dx,int dy,int b,int e);" -Name M -Namespace W; [W.M]::mouse_event(0x0800,0,0,$delta,0);',
      ]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output:
            'Windows 滚动失败（PowerShell）：${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}',
      );
    }
    return AgentToolResult(ok: false, output: '当前平台不支持滚动');
  }

  Future<AgentToolResult> _keyPress(String key) async {
    final k = key.trim();
    if (Platform.isMacOS) {
      final code = _macKeyCode(k);
      // R4-3：白名单内未映射键（不应出现）或未来新增键明确失败，
      // 不回落 Enter 误操作。
      if (code == null) {
        return AgentToolResult(
          ok: false,
          output: 'macOS 暂不支持按键 $k（无 key code 映射），已拒绝执行',
        );
      }
      final r = await _run('osascript', [
        '-e',
        'tell application "System Events" to key code $code',
      ]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output:
            'macOS 按键失败：需辅助功能授权（${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}）',
      );
    }
    if (Platform.isLinux) {
      final r = await _run('xdotool', ['key', k]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: 'Linux 按键失败：需安装 xdotool（${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}）',
      );
    }
    if (Platform.isWindows) {
      // A13：元字符先按 SendKeys 官方转义，再走 PowerShell 引号内嵌
      // （`"`→`""`），避免 `+()^%{}` 被当修饰符/分组执行。
      final send = _escapeSendKeys(k).replaceAll('"', '""');
      final r = await _run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait("$send");',
      ]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output:
            'Windows 按键失败（PowerShell）：${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}',
      );
    }
    return AgentToolResult(ok: false, output: '当前平台不支持按键');
  }

  /// macOS 特殊键 → key code（https://eastmanreference.com/complete-list-of-applescript-key-codes ）。
  /// R4-3：白名单键逐一显式映射；未映射返回 null 由调用方明确失败——
  /// 此前 default 回落 36（Enter），`computer_press Home` 实际按 Enter，
  /// 可能误确认对话框/误发送。
  int? _macKeyCode(String key) {
    switch (key.trim().toLowerCase()) {
      case 'enter':
        return 36;
      case 'tab':
        return 48;
      case 'space':
        return 49;
      case 'backspace':
        return 51;
      case 'escape':
      case 'esc':
        return 53;
      case 'delete':
        return 117;
      case 'left':
        return 123;
      case 'right':
        return 124;
      case 'down':
        return 125;
      case 'up':
        return 126;
      case 'home':
        return 115;
      case 'end':
        return 119;
      case 'pageup':
        return 116;
      case 'pagedown':
        return 121;
      case 'f1':
        return 122;
      case 'f2':
        return 120;
      case 'f3':
        return 99;
      case 'f4':
        return 118;
      case 'f5':
        return 96;
      case 'f6':
        return 97;
      case 'f7':
        return 98;
      case 'f8':
        return 100;
      case 'f9':
        return 101;
      case 'f10':
        return 109;
      case 'f11':
        return 103;
      case 'f12':
        return 111;
      default:
        return null;
    }
  }

  Future<AgentToolResult> _keyType(String text) async {
    if (Platform.isMacOS) {
      // 经剪贴板中转粘贴：避免 keystroke 对中文/特殊字符转义问题。
      // 注意：会覆盖系统剪贴板，审批弹窗已提示。
      // R4-1：文本经 pbcopy stdin 直写（参数化通道），不再经 `sh -c`
      // 字符串拼接——heredoc 内嵌时 text 含分隔符行即提前闭合，
      // 其后内容会作为 shell 命令执行，审批「键入 X」变任意执行。
      // text 任何内容（分隔符行/换行/元字符）只能进剪贴板。
      // R-PBCOPY-GUARD：整段包 try——pbcopy 缺失或提前退出时
      // ProcessException/写已关闭管道异常此前向上传播（同文件其他
      // 系统动作均走全捕获的 _run），工具直接崩而非回可读失败。
      try {
        final pb = await Process.start('pbcopy', []);
        pb.stdout.drain<void>();
        pb.stderr.drain<void>();
        pb.stdin.write(text);
        await pb.stdin.flush();
        await pb.stdin.close();
        final pbCode = await pb.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            pb.kill();
            return -1;
          },
        );
        if (pbCode != 0) {
          return AgentToolResult(ok: false, output: 'macOS 键入失败：pbcopy 写剪贴板退出码 $pbCode');
        }
      } catch (e) {
        return AgentToolResult(ok: false, output: 'macOS 键入失败：pbcopy 不可用（$e）');
      }
      final r = await _run('osascript', [
        '-e',
        'tell application "System Events" to keystroke "v" using command down',
      ]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output:
            'macOS 键入失败：需辅助功能授权（${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}）',
      );
    }
    if (Platform.isLinux) {
      final r = await _run('xdotool', ['type', '--', text]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: 'Linux 键入失败：需安装 xdotool（${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}）',
      );
    }
    if (Platform.isWindows) {
      return AgentToolResult(ok: false, output: 'Windows 键入暂不支持（防 SendKeys 转义误操作），请用剪贴板粘贴后按键');
    }
    return AgentToolResult(ok: false, output: '当前平台不支持键入');
  }

  Future<AgentToolResult> _systemOpen(String target) async {
    if (Platform.isMacOS) {
      final r = await _run('open', [target]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: '打开失败（open）：${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}',
      );
    }
    if (Platform.isLinux) {
      final r = await _run('xdg-open', [target]);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: '打开失败（xdg-open）：${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}',
      );
    }
    if (Platform.isWindows) {
      // S3-1：target 已过元字符校验，仍以带引号形式整体传参（等价 shell 的
      // '"$target"'）——start 把引号内当一个参数，空格/括号不再被拆分或解析。
      final r = await _run('cmd', ['/c', 'start', '', '"$target"']);
      if (r.exitCode == 0) return _ok();
      return AgentToolResult(
        ok: false,
        output: '打开失败（start）：${r.err.isEmpty ? 'exit=${r.exitCode}' : r.err}',
      );
    }
    return AgentToolResult(ok: false, output: '当前平台不支持打开');
  }
}
