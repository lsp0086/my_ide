import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_colors.dart';

/// B3-7 命令面板动作（Zed/Void 基线 https://zed.dev/ ）：id 全局唯一，
/// ide_shell 侧 `_runPaletteAction` 分发到既有面板/命令处理器——不新建
/// 平行机制，命令面板只是既有入口的键盘化聚合。
class PaletteAction {
  const PaletteAction({
    required this.id,
    required this.title,
    this.section = '',
    this.keywords = const [],
  });

  final String id;
  final String title;
  final String section;

  /// 检索关键词（别名/拼音首字母/英文），命中即返回。
  final List<String> keywords;
}

/// 主要命令注册表（测试可见）：断言"动作清单与注册表一致"时以本表为准。
/// 覆盖：侧栏面板（资源/搜索/问题/版本/统计/待办/WebDAV/MCP/电脑/远程）、
/// 设置各分区、编辑器保存、对话新建。
const List<PaletteAction> kCommandPaletteActions = [
  PaletteAction(id: 'panel:explorer', title: '资源管理器', section: '面板', keywords: ['files', 'explorer', 'wenjian']),
  PaletteAction(id: 'panel:search', title: '全局搜索', section: '面板', keywords: ['search', 'sousuo', 'find']),
  PaletteAction(id: 'panel:problems', title: '问题面板', section: '面板', keywords: ['problems', 'wenti', 'diagnostics']),
  PaletteAction(id: 'panel:git', title: '版本与恢复', section: '面板', keywords: ['version', 'banben', 'restore', 'checkpoint']),
  PaletteAction(id: 'panel:stats', title: '统计热力图', section: '面板', keywords: ['stats', 'tongji', 'heatmap']),
  PaletteAction(id: 'panel:todos', title: '待办清单', section: '面板', keywords: ['todos', 'daiban', 'focus']),
  PaletteAction(id: 'panel:webdav', title: 'WebDAV 备份', section: '面板', keywords: ['webdav', 'beifen', 'backup']),
  PaletteAction(id: 'panel:mcp', title: 'MCP 服务器', section: '面板', keywords: ['mcp', 'fuwuqi']),
  PaletteAction(id: 'panel:computer', title: '电脑操控', section: '面板', keywords: ['computer', 'diannao']),
  PaletteAction(id: 'panel:remote', title: '远程设备', section: '面板', keywords: ['remote', 'yuancheng', 'feishu', 'dingtalk']),
  PaletteAction(id: 'settings:open', title: '设置', section: '设置', keywords: ['settings', 'shezhi', 'preferences']),
  PaletteAction(id: 'settings:providers', title: '设置：模型供应商', section: '设置', keywords: ['provider', 'gongyingshang', 'model']),
  PaletteAction(id: 'settings:agent', title: '设置：Agent', section: '设置', keywords: ['agent', 'zhineng']),
  PaletteAction(id: 'settings:skills', title: '设置：Skills', section: '设置', keywords: ['skills', 'jineng']),
  PaletteAction(id: 'settings:memory', title: '设置：长期记忆', section: '设置', keywords: ['memory', 'jiyi']),
  PaletteAction(id: 'settings:lsp', title: '设置：语言服务器', section: '设置', keywords: ['lsp', 'yuyan', 'language']),
  PaletteAction(id: 'settings:shortcuts', title: '设置：快捷键', section: '设置', keywords: ['shortcut', 'kuaijiejian', 'keybindings']),
  PaletteAction(id: 'settings:clean', title: '设置：清理项目', section: '设置', keywords: ['clean', 'qingli', 'clear']),
  PaletteAction(id: 'editor:save', title: '保存当前文件', section: '编辑器', keywords: ['save', 'baocun']),
  PaletteAction(id: 'editor:saveAll', title: '保存全部脏标签', section: '编辑器', keywords: ['saveAll', 'quanbu', 'all']),
  PaletteAction(id: 'chat:new', title: '新建对话', section: '对话', keywords: ['new', 'chat', 'xinzeng', 'duihua']),
];

/// 检索纯函数（测试可见）：标题/分区/关键词做大小写不敏感子串匹配，
/// 保持注册表原顺序（稳定排序，不跳动）；空 query 返回全量。
List<PaletteAction> filterPaletteActionsForTest(
  List<PaletteAction> actions,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return List<PaletteAction>.from(actions);
  return actions
      .where(
        (a) =>
            a.title.toLowerCase().contains(q) ||
            a.section.toLowerCase().contains(q) ||
            a.keywords.any((k) => k.toLowerCase().contains(q)),
      )
      .toList();
}

/// 命令面板控件：搜索框（autofocus）+ 结果列表 + 键盘全流程可达
/// （↑/↓ 选择、Enter 执行、Esc 关闭）。
class CommandPalette extends StatefulWidget {
  const CommandPalette({
    super.key,
    required this.onRun,
    required this.onClose,
  });

  /// 执行命令：回调 id 由 ide_shell 分发。
  final ValueChanged<String> onRun;
  final VoidCallback onClose;

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  List<PaletteAction> _matches = kCommandPaletteActions;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_refilter);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.removeListener(_refilter);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _refilter() {
    setState(() {
      _matches = filterPaletteActionsForTest(kCommandPaletteActions, _controller.text);
      _selected = 0;
    });
  }

  void _move(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _selected = (_selected + delta) % _matches.length;
      if (_selected < 0) _selected += _matches.length;
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        widget.onClose();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
        if (_matches.isNotEmpty) widget.onRun(_matches[_selected].id);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return GestureDetector(
      onTap: widget.onClose,
      child: ColoredBox(
        color: Colors.black54,
        child: SafeArea(
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
                child: ColoredBox(
                  color: colors.panelElevated,
                  child: Focus(
                    focusNode: _focus,
                    onKeyEvent: _onKey,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: TextField(
                            controller: _controller,
                            autofocus: true,
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '输入命令（支持别名/英文/拼音）…',
                              prefixIcon: const Icon(Icons.search_rounded, size: 16),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        Flexible(
                          child: _matches.isEmpty
                              ? Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    '无匹配命令',
                                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _matches.length,
                                  itemBuilder: (context, i) {
                                    final a = _matches[i];
                                    final active = i == _selected;
                                    return ListTile(
                                      dense: true,
                                      selected: active,
                                      selectedTileColor: colors.accentSoft,
                                      title: Text(a.title, style: const TextStyle(fontSize: 12)),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            a.section,
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: colors.textMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                      onTap: () => widget.onRun(a.id),
                                    );
                                  },
                                ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                          child: Text(
                            '↑↓ 选择 · Enter 执行 · Esc 关闭（Ctrl/Cmd+K 唤起）',
                            style: TextStyle(fontSize: 10, color: colors.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
