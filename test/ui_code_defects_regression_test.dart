import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_ide/theme/app_colors.dart';

/// E 节「UI 代码缺陷」（任务清单 E1~E12）回归。
/// 交互项（E2/E11/E12）以源码口径固化修复形态，主题/语义色项附 IdeColors
/// 行为断言；私有 part 类无法在测试内直接构造，源码断言是既定的可执行校验。

Future<String> readLib(String relPath) async {
  // 整库口径：主文件 + 同名 `_` 前缀 part 拼接（库拆分后断言不漂移）。
  final base = File('lib/$relPath');
  var out = await base.readAsString();
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
    out += await f.readAsString();
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // —— E1：死代码清理 ————————————————————————————————————————————

  group('E1 ide_shell_chat_chips 死代码清理', () {
    test('_ModeChip/_TemplateChip/_ModelChip 已删除且无实例化残留', () async {
      final src = await readLib('ui/ide_shell_chat_chips.dart');
      expect(src.contains('class _ModeChip'), isFalse);
      expect(src.contains('class _TemplateChip'), isFalse);
      expect(src.contains('class _ModelChip'), isFalse);
      // 实例化形态（_ModeChip(/_TemplateChip(/_ModelChip(）亦不得残留。
      expect(RegExp(r'_ModeChip\(').hasMatch(src), isFalse);
      expect(RegExp(r'_TemplateChip\(').hasMatch(src), isFalse);
      expect(RegExp(r'_ModelChip\(').hasMatch(src), isFalse);
    });

    test('仍被 composer 使用的 _ModelMenuRow/_SoftMiniChip 保留', () async {
      final src = await readLib('ui/ide_shell_chat_chips.dart');
      expect(src.contains('class _ModelMenuRow extends StatefulWidget'), isTrue);
      expect(src.contains('class _SoftMiniChip extends StatelessWidget'), isTrue);
      final composer = await readLib('ui/ide_shell_chat_composer.dart');
      expect(composer.contains('_ModelMenuRow('), isTrue);
    });

    test('lib/ui 全目录无 _ModeChip/_TemplateChip/_ModelChip 残留', () async {
      final dir = Directory('lib/ui');
      final buf = StringBuffer();
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        // ignore: avoid_slow_async_io
        buf.write(await f.readAsString());
        buf.write('\n');
      }
      final joined = buf.toString();
      expect(joined.contains('class _ModeChip'), isFalse);
      expect(joined.contains('class _TemplateChip'), isFalse);
      expect(joined.contains('class _ModelChip'), isFalse);
      // 实例化/类型注解形态亦无残留。
      expect(RegExp(r'_ModeChip\(').hasMatch(joined), isFalse);
      expect(RegExp(r'_TemplateChip\(').hasMatch(joined), isFalse);
      expect(RegExp(r'_ModelChip\b').hasMatch(joined), isFalse);
    });
  });

  // —— E2：规则编辑器控制器随行走 ———————————————————————————————————

  group('E2 自动审批规则编辑器控制器生命周期', () {
    test('行对象持有 controller，build 内不再新建', () async {
      final src = await readLib('ui/ide_shell_settings_rules.dart');
      // _RuleRow 行对象存在，且随行建/销 controller。
      expect(src.contains('class _RuleRow {'), isTrue);
      expect(
        RegExp(r'patternCtrl = TextEditingController\(text: pattern\)').hasMatch(
          src,
        ),
        isTrue,
      );
      // build 内直接 TextEditingController(text:...) 的形态已消除。
      expect(RegExp(r'controller:\s*TextEditingController\(').hasMatch(src), isFalse);
      // TextField 不再把 pattern 塞进 key。
      expect(src.contains('ValueKey('), isFalse);
      expect(src.contains("'rule-pattern-'"), isFalse);
    });

    test('State dispose 与删行路径均回收 controller', () async {
      final src = await readLib('ui/ide_shell_settings_rules.dart');
      expect(src.contains('void dispose()'), isTrue);
      // 重载与删行两条路径都调 r.dispose()/row.dispose()。
      expect(RegExp(r'for \(final r in _rows\) \{\s*r\.dispose\(\);').hasMatch(src), isTrue);
      expect(src.contains('row.dispose();'), isTrue);
    });
  });

  // —— E3：图片缩略一次性加载 ————————————————————————————————————

  group('E3 _ChatImageThumb 改 StatefulWidget 缓存加载', () {
    test('future 只创建一次并缓存，重复 build 不重复读盘', () async {
      final src = await readLib('ui/ide_shell_chat_bubble.dart');
      expect(src.contains('class _ChatImageThumb extends StatefulWidget'), isTrue);
      expect(src.contains('class _ChatImageThumbState'), isTrue);
      // 依赖就绪后一次性创建（??=），后续 build 复用同一 future。
      expect(RegExp(r'_future \?\?= _loadBytes\(\)').hasMatch(src), isTrue);
      expect(src.contains('future: _future,'), isTrue);
      // 旧形态：build 内每次调 _loadBytes(context) 新建 future。
      expect(RegExp(r'future: _loadBytes\(context\)').hasMatch(src), isFalse);
    });
  });

  // —— E4：落盘失败横幅语义色 ————————————————————————————————————

  group('E4 落盘失败横幅改 IdeColors 语义色', () {
    test('暗红/浅粉硬编码移除，改用 dangerStrong + 白字', () async {
      final src = await readLib('ui/ide_shell_chat.dart');
      expect(src.contains('0xFF5C2B2B'), isFalse);
      expect(src.contains('0xFFFFC9C9'), isFalse);
      expect(src.contains('color: colors.dangerStrong'), isTrue);
      expect(src.contains('color: Colors.white,'), isTrue);
    });
  });

  // —— E5：贡献热力图亮暗两套色阶 ————————————————————————————————

  group('E5 贡献热力图按主题亮度分色阶', () {
    test('亮暗两套 levels 且暗色空格不用浅灰', () async {
      final src = await readLib('ui/stats_panel.dart');
      expect(src.contains('static const _lightLevels'), isTrue);
      expect(src.contains('static const _darkLevels'), isTrue);
      expect(src.contains('_levelsFor(Theme.of(context).brightness)'), isTrue);
      // 暗色档内不得出现亮色空格色 #EBEDF0（刺眼根因）。
      final dark = src.substring(src.indexOf('_darkLevels'));
      expect(dark.contains('0xFFEBEDF0'), isFalse);
      // 亮色档保留 GitHub 空格外观。
      final light = src.substring(src.indexOf('_lightLevels'));
      expect(light.contains('0xFFEBEDF0'), isTrue);
    });

    test('绘制与图例使用点改局部 levels', () async {
      final src = await readLib('ui/stats_panel.dart');
      expect(src.contains('color: levels[level]'), isTrue);
      expect(src.contains('color: levels[i]'), isTrue);
      expect(src.contains('_levels[level]'), isFalse);
      expect(src.contains('_levels.length'), isFalse);
    });
  });

  // —— E6：会话标签条截断 ————————————————————————————————————————

  group('E6 会话标签条长标题截断', () {
    test('Text 改用 _chatLabel 截断 + ellipsis', () async {
      final src = await readLib('ui/ide_shell_chat.dart');
      expect(src.contains('_chatLabel(s),'), isTrue);
      // 直接把 s.title 原样赋给 Text 的形态已消除。
      expect(RegExp(r'Text\(\s*s\.title,').hasMatch(src), isFalse);
      // 截断文本带省略兜底。
      expect(
        RegExp(
          r'_chatLabel\(s\),\s*maxLines: 1,\s*softWrap: false,\s*overflow: TextOverflow\.ellipsis',
        ).hasMatch(src),
        isTrue,
      );
    });
  });

  // —— E7：编辑器 tab 文件名限宽 ————————————————————————————————————

  group('E7 编辑器 tab 文件名限宽 + ellipsis', () {
    test('ConstrainedBox 最大宽 180 + 省略', () async {
      final src = await readLib('ui/ide_shell_editor.dart');
      expect(src.contains('constraints: const BoxConstraints(maxWidth: 180)'), isTrue);
      expect(
        RegExp(
          r"widget\.dirty \? '• \$\{widget\.label\}' : widget\.label,\s*maxLines: 1,\s*softWrap: false,\s*overflow: TextOverflow\.ellipsis",
        ).hasMatch(src),
        isTrue,
      );
    });
  });

  // —— E8：无工作区状态栏路径 ——————————————————————————————————————

  group('E8 无工作区时状态栏回落文件名', () {
    test('rootPath==null 显示 basename，有根仍走 relative', () async {
      final src = await readLib('ui/ide_shell_editor.dart');
      expect(src.contains('workspace.rootPath == null'), isTrue);
      expect(src.contains('p.basename(active.path)'), isTrue);
      expect(
        src.contains('p.relative(active.path, from: workspace.rootPath)'),
        isTrue,
      );
    });
  });

  // —— E9：危险语义色统一 ——————————————————————————————————————————

  group('E9 danger/dangerStrong 语义色接入', () {
    test('IdeColors 提供亮暗两套危险语义色', () {
      expect(IdeColors.dark.danger, const Color(0xFFE03131));
      expect(IdeColors.dark.dangerStrong, const Color(0xFF5C2B2B));
      expect(IdeColors.light.danger, const Color(0xFFD03A3A));
      expect(IdeColors.light.dangerStrong, const Color(0xFF8A1F1F));
    });

    test('buildIdeTheme/copyWith/lerp 均携带危险语义色', () {
      final dark = buildIdeTheme(Brightness.dark).extension<IdeColors>();
      expect(dark, isNotNull);
      expect(dark!.danger, IdeColors.dark.danger);
      expect(dark.dangerStrong, IdeColors.dark.dangerStrong);
      final light = buildIdeTheme(Brightness.light).extension<IdeColors>();
      expect(light!.dangerStrong, IdeColors.light.dangerStrong);
      final copied = IdeColors.light.copyWith(accent: const Color(0xFF000000));
      expect(copied.danger, IdeColors.light.danger);
      expect(copied.dangerStrong, IdeColors.light.dangerStrong);
      final lerped = IdeColors.light.lerp(IdeColors.dark, 0);
      expect(lerped.danger, IdeColors.light.danger);
      // 插值中枢不抛空（t=0.5 得到两色中间值）。
      final mid = IdeColors.light.lerp(IdeColors.dark, 0.5);
      expect(mid.danger, isNotNull);
    });

    test('回退按钮两处引用 IdeColors.danger 且源码无硬编码红', () async {
      final colorsSrc = await readLib('theme/app_colors.dart');
      expect(colorsSrc.contains('required this.danger,'), isTrue);
      expect(colorsSrc.contains('required this.dangerStrong,'), isTrue);
      final turn = await readLib('ui/ide_shell_chat_turn.dart');
      expect(turn.contains('0xFFE03131'), isFalse);
      expect(turn.contains('backgroundColor: IdeColors.of(ctx).danger'), isTrue);
      final diff = await readLib('ui/diff_view.dart');
      expect(diff.contains('0xFFE03131'), isFalse);
      expect(diff.contains('final color = IdeColors.of(context).danger;'), isTrue);
    });
  });

  // —— E10：空态新建按钮禁用条件 ————————————————————————————————————

  group('E10 空态新建会话按钮禁用条件', () {
    test('判 !hasProject || runner.running，恒 false 死条件移除', () async {
      final src = await readLib('ui/ide_shell_chat.dart');
      expect(src.contains('onPressed: !hasProject || runner.running'), isTrue);
      // 空态分支（t.emptyChat 附近）不再出现 current != null && 的恒假判据。
      final anchor = src.indexOf('t.emptyChat');
      expect(anchor, greaterThan(0));
      final seg = src.substring(anchor, anchor + 700);
      expect(seg.contains('current != null &&'), isFalse);
      expect(seg.contains('!hasProject || runner.running'), isTrue);
    });
  });

  // —— E11：语言服务器空值反馈 ——————————————————————————————————————

  group('E11 自定义语言服务器空值提交反馈', () {
    test('空 id/命令出 SnackBar 而非静默 return', () async {
      final src = await readLib('ui/ide_shell_settings_agent.dart');
      expect(src.contains('if (id.isEmpty || command.isEmpty) {'), isTrue);
      expect(src.contains("'id 不能为空'"), isTrue);
      expect(src.contains("'命令不能为空'"), isTrue);
      // 两条反馈均在 setState/落库之前给出。
      final emptyIdx = src.indexOf('if (id.isEmpty || command.isEmpty) {');
      final persistIdx = src.indexOf(
        'setCustomLanguageServers(list)',
        emptyIdx,
      );
      expect(persistIdx, greaterThan(emptyIdx));
    });
  });

  // —— E12：软菜单布局竞态 ——————————————————————————————————————————

  group('E12 _showSoftMenu 锚点布局竞态', () {
    test('等一帧拿到布局再算坐标，不再静默返回 null', () async {
      final src = await readLib('ui/ide_shell_chat_composer.dart');
      expect(src.contains('WidgetsBinding.instance.endOfFrame'), isTrue);
      expect(src.contains('whenLaidOut()'), isTrue);
      // 限定 _showSoftMenu 函数区间：其内旧早退形态（未布局即
      // Future.value(null)）已移除（别处右键菜单保留原逻辑，不受影响）。
      final start = src.indexOf('Future<T?> _showSoftMenu<T>(');
      expect(start, greaterThan(0));
      final seg = src.substring(start);
      expect(seg.contains('Future.value(null)'), isFalse);
      // 跨帧使用 context 处有显式豁免注释（安全性由渲染盒非空保证）。
      expect(seg.contains('// ignore: use_build_context_synchronously'), isTrue);
    });
  });
}
