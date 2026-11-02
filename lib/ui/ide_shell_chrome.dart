part of 'ide_shell.dart';

/// 外壳 chrome：面板容器/拖拽手柄/活动栏/面板头 widget。
class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: colors.shadow,
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        child: SizedBox(
          width: 8,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 3,
              height: 36,
              decoration: BoxDecoration(
                color: _hover ? colors.accent : colors.divider,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ActivityBar extends StatelessWidget {
  const _ActivityBar({
    required this.width,
    required this.active,
    required this.onTap,
  });

  final double width;
  final ActivityItem active;
  final ValueChanged<ActivityItem> onTap;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: colors.activityBar,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.border),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          _ActivityIcon(
            icon: Icons.folder_outlined,
            selected: active == ActivityItem.explorer,
            tooltip: '文件列表',
            onTap: () => onTap(ActivityItem.explorer),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.search_rounded,
            selected: active == ActivityItem.search,
            tooltip: '搜索',
            onTap: () => onTap(ActivityItem.search),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.error_outline,
            selected: active == ActivityItem.problems,
            tooltip: '问题',
            onTap: () => onTap(ActivityItem.problems),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.account_tree_outlined,
            selected: active == ActivityItem.git,
            tooltip: '查看节点',
            onTap: () => onTap(ActivityItem.git),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.grid_on_rounded,
            selected: active == ActivityItem.stats,
            tooltip: '贡献统计',
            onTap: () => onTap(ActivityItem.stats),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.extension_outlined,
            selected: active == ActivityItem.mcp,
            tooltip: 'MCP',
            onTap: () => onTap(ActivityItem.mcp),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.computer_outlined,
            selected: active == ActivityItem.computer,
            tooltip: '电脑操控',
            onTap: () => onTap(ActivityItem.computer),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.phone_android_outlined,
            selected: active == ActivityItem.remoteDevices,
            tooltip: '远程设备',
            onTap: () => onTap(ActivityItem.remoteDevices),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.checklist_rounded,
            selected: active == ActivityItem.todos,
            tooltip: '待办清单',
            onTap: () => onTap(ActivityItem.todos),
          ),
          const SizedBox(height: 4),
          _ActivityIcon(
            icon: Icons.cloud_outlined,
            selected: active == ActivityItem.webdav,
            tooltip: 'WebDAV 备份',
            onTap: () => onTap(ActivityItem.webdav),
          ),
          const Spacer(),
          _ActivityIcon(
            icon: Icons.settings_outlined,
            selected: active == ActivityItem.settings,
            tooltip: '设置',
            onTap: () => onTap(ActivityItem.settings),
          ),
        ],
      ),
    );
  }
}

class _ActivityIcon extends StatefulWidget {
  const _ActivityIcon({
    required this.icon,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_ActivityIcon> createState() => _ActivityIconState();
}

class _ActivityIconState extends State<_ActivityIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final bg = widget.selected
        ? colors.accentSoft
        : _hover
        ? colors.panelHover
        : Colors.transparent;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              widget.icon,
              size: 20,
              color: widget.selected ? colors.accent : colors.iconIdle,
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}
