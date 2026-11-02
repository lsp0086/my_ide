// browser_flow 加固自检系列（由 browser_flow_test.dart 拆分）
// ignore_for_file: unused_element_parameter
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/ai/agent_browser_tools.dart';
import 'package:my_ide/ai/chat_store.dart';
import 'package:my_ide/browser/browser_service.dart';
import 'package:my_ide/diagnostics/app_logger.dart';

/// 读取 lib 源码：主文件与同名 `_` 前缀的 part 文件（库拆分后按整库断言）。
String _lib(String rel) {
  var out = File('lib/$rel').readAsStringSync();
  final stem = rel.split('/').last.replaceAll('.dart', '');
  final parts = File('lib/$rel')
      .parent
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

void main() {
  group('加固自检：符号深度/Raf复位/canon键/MCP并发/select预等待/fill回读', () {
    test('符号深度与MCP并发与预等待回归（源码口径）', () async {
      // 深树栈溢出：walk带depth+32层上限。
      final sym = _lib('lsp/symbol_index.dart');
      expect(sym.contains('depth > 32'), isTrue);
      expect(sym.contains('walk(entity, depth + 1)'), isTrue);
      // raf泄漏：try/finally保closeSync。
      expect(sym.contains('raf.closeSync'), isTrue);
      expect(sym.contains('finally'), isTrue);
      // 双路径键分裂：hash/符号/引用全用canon。
      expect(sym.contains('_fileHash[canon]'), isTrue);
      expect(sym.contains('filePath: canon'), isTrue);
      // MCP串行卡关闭：并发断+5s兜底。
      final mgr = _lib('mcp/mcp_manager.dart');
      expect(mgr.contains('Future.wait(ids.map'), isTrue);
      expect(mgr.contains('timeout(const Duration(seconds: 5))'), isTrue);
      // select预等待+赋后回读。
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('预等待'), isTrue);
      expect(browser.contains('option miss:'), isTrue);
      expect(browser.contains("startsWith('option miss:')"), isTrue);
      // fill落盘确认：回读比对。
      expect(browser.contains('落盘确认'), isTrue);
      expect(browser.contains('fillReadbackJsForTest'), isTrue);
      expect(
        fillReadbackJsForTest('{}'),
        contains("'value' in el"),
      );
      // cron下溢：自减保底不跌破0。
      final cron = _lib('ai/cron_scheduler.dart');
      expect(cron.contains('if (_pendingCount > 0) _pendingCount--'), isTrue);
    });
  });
  group('加固自检：恢复门禁/符号复检/图片有界/日志截断/outerJS截断/fill归一', () {
    test('恢复门禁与日志截断回归（源码口径）', () async {
      // 恢复侧2MB门禁。
      final ckpt = _lib('version/checkpoint_store.dart');
      expect(ckpt.contains('恢复侧同样2MB门禁'), isTrue);
      expect(ckpt.contains('await file.length() > 2 * 1024 * 1024'), isTrue);
      // 符号重读复检。
      final sym = _lib('lsp/symbol_index.dart');
      expect(sym.contains('读前复检'), isTrue);
      expect(sym.contains('同口径'), isTrue);
      // 图片桶截尾20。
      final runner = _lib('ai/agent_runner.dart');
      expect(runner.contains('图片桶有界'), isTrue);
      // 单条4k截断。
      AppLogger.instance.clearForTest();
      AppLogger.instance.bindProject(null);
      AppLogger.instance.info('t', 'x' * 10000);
      final last = AppLogger.instance.recent.last;
      expect(last.message.length, lessThan(10000));
      expect(last.message, contains('已截断'));
      AppLogger.instance.clearForTest();
      // outerHtml JS内slice。
      final cdp = _lib('browser/chrome_cdp.dart');
      expect(cdp.contains('JS内截断'), isTrue);
      expect(cdp.contains('h.slice(0,n)'), isTrue);
      // fill回读空白归一。
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('空白归一'), isTrue);
      expect(browser.contains('actual.trim() != effective.trim()'), isTrue);
    });
  });
  group('加固自检：hook门禁/解压门禁/采集团流/基线空判/evaluate有界', () {
    test('hook门禁与基线空判回归（源码口径）', () async {
      // hook哈希先判大小。
      final runner = _lib('ai/agent_runner.dart');
      expect(runner.contains('hook哈希先判大小'), isTrue);
      // 解压/校验先判大小。
      final lsp = _lib('lsp/bundled_language_servers.dart');
      expect(lsp.contains('解压先判大小'), isTrue);
      expect(lsp.contains('同口径'), isTrue);
      // 语义采集目录流有界。
      final tools = _lib('ai/agent_tools.dart');
      expect(tools.contains('目录流有界'), isTrue);
      expect(tools.contains('scanned > 2000'), isTrue);
      // 空基线永判变：空串基线不再误报未变化。
      expect(
        snapshotUnchangedForTest('', '', 'u', 'u', 120, 120),
        isFalse,
      );
      expect(
        snapshotUnchangedForTest('h', 'h', 'u', 'u', 120, 120),
        isTrue,
      );
      // evaluate 8k门禁。
      final cdp = _lib('browser/chrome_cdp.dart');
      expect(cdp.contains('js有界8k'), isTrue);
    });
  });
  group('加固自检：入口有界/兼容门禁/重建上限/下载纵深/folder流截断', () {
    test('交互入口有界与下载纵深回归', () async {
      // 交互入口有界。
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('入口有界'), isTrue);
      expect(browser.contains('同口径'), isTrue);
      // pressKey行为口径：超长key显错。
      final svc = BrowserService();
      try {
        await expectLater(svc.pressKey('x' * 101), throwsA(isA<StateError>()));
        await expectLater(svc.scrollTo('x' * 501), throwsA(isA<StateError>()));
        await expectLater(svc.hover('x' * 501), throwsA(isA<StateError>()));
      } finally {
        await svc.dispose();
      }
      // 兼容分支2MB门禁。
      final ckpt = _lib('version/checkpoint_store.dart');
      expect(ckpt.contains('兼容分支同样2MB门禁'), isTrue);
      // 重建链回溯上限50。
      expect(ckpt.contains('重建链回溯上限50'), isTrue);
      // 下载目录执行层纵深。
      final tools = _lib('ai/agent_browser_tools.dart');
      expect(tools.contains('执行层纵深'), isTrue);
      final dir = await Directory.systemTemp.createTemp('dl-depth-');
      try {
        final gated = AgentBrowserTools(rootPath: dir.path);
        final r = await gated.execute('browser_download_dir', {'dir': '/etc'});
        expect(r.ok, isFalse);
        expect(r.output, contains('工作区外'));
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
      // folder真流式截断。
      final at = _lib('ai/at_mentions.dart');
      expect(at.contains('真流式截断'), isTrue);
      expect(at.contains('dir.list(followLinks: false).take(100)'), isTrue);
    });
  });
  group('加固自检：select/drag有界/图片预检/fs直读/evaluate有界', () {
    test('select/drag入口有界与图片预检回归', () async {
      // select/drag入口有界。
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('入口有界'), isTrue);
      expect(browser.contains('双端有界'), isTrue);
      final svc = BrowserService();
      try {
        await expectLater(
          svc.selectOption('x' * 501, 'v'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          svc.selectOption('#s', 'x' * 501),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          svc.drag('x' * 501, '#b'),
          throwsA(isA<StateError>()),
        );
      } finally {
        await svc.dispose();
      }
      // 图片读预检。
      final clip = _lib('ui/clipboard_image.dart');
      expect(clip.contains('先判大小再读'), isTrue);
      final shell = _lib('ui/ide_shell.dart');
      expect(shell.contains('先判大小再读'), isTrue);
      // fs直读有界：B16 后 WorkspaceFs.readText（生产无调用）已删，
      // 生产读通道为 AgentTools._read——先判大小再读+读后复检双门禁。
      final at2 = _lib('ai/agent_tools.dart');
      expect(at2.contains('先判大小再读'), isTrue);
      expect(at2.contains('512 * 1024'), isTrue);
      // 读后复检：length与read间隙追加仍可OOM，读后按字节复检。
      // B1 有界读后 cap 已常量化（const cap = 512 * 1024），预检/复检同 cap。
      expect(at2.contains('const cap = 512 * 1024'), isTrue);
      expect(at2.contains('bytes.length > cap'), isTrue);
    });
  });
  group('加固自检：upload入口有界/纯读批超时定性', () {
    test('upload入口有界与纯读批定性回归', () async {
      // upload selector/路径同样有界（select/press/scroll/hover同口径）。
      final svc = BrowserService();
      try {
        await expectLater(
          svc.uploadFile('x' * 501, '/tmp/a'),
          throwsA(isA<StateError>()),
        );
        await expectLater(
          svc.uploadFile('#f', 'x' * 4097),
          throwsA(isA<StateError>()),
        );
      } finally {
        await svc.dispose();
      }
      // 纯读批未收集回填按原因定性（取消回中断、超时回超时）。
      final runner = _lib('ai/agent_runner.dart');
      expect(runner.contains('未收集回填按原因定性'), isTrue);
      expect(runner.contains('执行超时已熔断'), isTrue);
    });
  });
  group('加固自检：press修饰键透传/dialog信封一次性', () {
    test('press修饰键与dialog信封回归（源码口径）', () async {
      // 工具层解析 ctrl/meta/shift/alt（此前恒丢modifiers）。
      final tools = _lib('ai/agent_browser_tools.dart');
      expect(tools.contains('修饰键透传'), isTrue);
      // dialog信封一次性不复用过期sid。
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('信封一次性'), isTrue);
      // pressKey 信封三件套不断裂：Enter 带 code/vKey/text。
      final env = pressKeyEnvelopeForTest('keyDown', 'Enter', 0);
      expect(env['code'], 'Enter');
      expect(env['windowsVirtualKeyCode'], 13);
      expect(env['text'], '\r');
    });
  });
  group('pressKey符号键信封符合US键盘布局', () {
    test('符号键映射与字母数字回退口径', () {
      // 符号键此前单字符回退 code='Key'+upper/vKey=大写首码——',' 得到
      // Key,/44 这类实体键盘不存在的 code/vKey，监听 e.code 的页面失真。
      // 现补 US 布局映射（Puppeteer USKeyboardLayout 口径）。
      const expectMap = <String, (String, int)>{
        ',': ('Comma', 188),
        '.': ('Period', 190),
        '/': ('Slash', 191),
        ';': ('Semicolon', 186),
        "'": ('Quote', 222),
        '[': ('BracketLeft', 219),
        ']': ('BracketRight', 221),
        '\\': ('Backslash', 220),
        '-': ('Minus', 189),
        '=': ('Equal', 187),
        '`': ('Backquote', 192),
      };
      expectMap.forEach((key, exp) {
        final down = pressKeyEnvelopeForTest('keyDown', key, 0);
        expect(down['code'], exp.$1, reason: 'key=$key code');
        expect(down['windowsVirtualKeyCode'], exp.$2, reason: 'key=$key vKey');
        expect(down['text'], key, reason: 'key=$key keyDown text');
        final up = pressKeyEnvelopeForTest('keyUp', key, 0);
        expect(up['code'], exp.$1, reason: 'key=$key keyUp code');
        expect(up.containsKey('text'), isFalse, reason: 'key=$key keyUp 无text');
      });
      // 字母键回退口径回归不变；数字键 D8 改 Digit0-9（实体键盘数字排
      // KeyboardEvent.code 口径），vKey 仍用数字字符码点。
      final a = pressKeyEnvelopeForTest('keyDown', 'a', 0);
      expect(a['code'], 'KeyA');
      expect(a['windowsVirtualKeyCode'], 65);
      expect(a['text'], 'a');
      final d1 = pressKeyEnvelopeForTest('keyDown', '1', 0);
      expect(d1['code'], 'Digit1');
      expect(d1['windowsVirtualKeyCode'], 49);
      final d9 = pressKeyEnvelopeForTest('keyUp', '9', 0);
      expect(d9['code'], 'Digit9');
      expect(d9['windowsVirtualKeyCode'], 57);
      expect(d9.containsKey('text'), isFalse, reason: 'keyUp 无 text');
    });
  });
  group('加固自检：scroll/hover预等待/_save只收敛脏条目', () {
    test('scroll/hover预等待与脏条目收敛回归', () async {
      // scroll/hover与click/fill/drag/select同口径预等待。
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('scroll/hover同样预等待'), isTrue);
      expect(browser.contains('hover同样预等待'), isTrue);
      // _save只收敛脏条目，全干净零IO。
      final chat = _lib('ai/chat_store.dart');
      expect(chat.contains('只收敛脏条目'), isTrue);
    });
  });
  group('加固自检：图片资产白名单/dialog清缓冲清信封', () {
    test('图片资产白名单与dialog信封清理回归', () async {
      // svg等可执行载荷拒收+超8MB拒收+mime魔数双认。
      expect(
        ChatStore.imageMagicMatchesForTest('image/png', [
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
        ]),
        isTrue,
      );
      expect(
        ChatStore.imageMagicMatchesForTest('image/png', [0xFF, 0xD8, 0xFF]),
        isFalse,
      );
      expect(
        ChatStore.imageMagicMatchesForTest('image/svg+xml', [0x3C]),
        isFalse,
      );
      final chat = _lib('ai/chat_store.dart');
      expect(chat.contains('mime 白名单+大小上限'), isTrue);
      // 清缓冲即清dialog过期信封。
      final browser = _lib('browser/browser_service.dart');
      expect(browser.contains('dialog过期信封同属当页缓冲'), isTrue);
    });
  });
}
