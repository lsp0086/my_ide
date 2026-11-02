part of 'mcp_settings_panel.dart';

/// MCP 面板子组件：Server 卡片与 Skills 区。
class _McpServerTile extends StatelessWidget {
  const _McpServerTile({
    required this.config,
    required this.status,
    required this.tools,
    this.logs = const [],
    required this.onToggle,
    required this.onConnect,
    required this.onDisconnect,
    required this.onEdit,
    required this.onDelete,
    required this.onRunTool,
    this.lastError,
    this.managedDenial,
  });

  final McpServerConfig config;
  final String status;
  final List<McpToolDef> tools;
  final List<String> logs;
  final String? lastError;

  /// G-R2-14：托管策略拒绝原因（非空即启用开关禁用）。
  final String? managedDenial;
  final ValueChanged<bool> onToggle;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<McpToolDef> onRunTool;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final statusColor = switch (status) {
      // E14：语义状态色随亮暗主题切换。
      'connected' => colors.statusOk,
      'connecting' => colors.statusWarn,
      'error' => colors.statusError,
      _ => colors.textMuted,
    };
    final statusLabel = switch (status) {
      'connected' => '已连接 · ${tools.length} 工具',
      'connecting' => '连接中…',
      'error' => '连接失败',
      _ => '未连接',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.panelHover.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.extension_outlined, size: 16, color: colors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  config.name,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(statusLabel,
                  style: TextStyle(color: statusColor, fontSize: 11.5)),
              const SizedBox(width: 8),
              // G-R2-14：托管拒绝时开关锁死在关（value false + onChanged
              // null），并显示原因——用户不可覆盖 deny/allowManagedOnly。
              Switch(
                value: managedDenial != null ? false : config.enabled,
                onChanged: managedDenial != null ? null : onToggle,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            config.transport == McpTransportType.stdio
                ? '${config.command} ${config.args.join(' ')}'
                : config.url,
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 11.5,
              fontFamily: 'Menlo',
            ),
          ),
          // G-R2-14：托管拒绝原因常显（不随连接状态隐藏）。
          if (managedDenial != null) ...[
            const SizedBox(height: 4),
            Text(
              managedDenial!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              // E14：语义状态色随亮暗主题切换。
              style: TextStyle(color: colors.statusWarn, fontSize: 11),
            ),
          ],
          if (lastError != null && status == 'error') ...[
            const SizedBox(height: 4),
            Text(
              lastError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              // E14：语义状态色随亮暗主题切换。
              style: TextStyle(color: colors.statusError, fontSize: 11),
            ),
          ],
          const SizedBox(height: 8),
          if (logs.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('日志', style: TextStyle(fontSize: 12)),
              children: [
                SizedBox(
                  height: 120,
                  child: ListView(
                    children: logs.reversed.take(30).map((line) => Align(
                      alignment: Alignment.centerLeft,
                      child: Text(line, style: TextStyle(color: colors.textMuted, fontSize: 10)),
                    )).toList(),
                  ),
                ),
              ],
            ),
          Row(
            children: [
              TextButton(
                onPressed: status == 'connected' ? onDisconnect : onConnect,
                child: Text(status == 'connected' ? '断开' : '连接'),
              ),
              TextButton(onPressed: onEdit, child: const Text('编辑')),
              TextButton(
                onPressed: onDelete,
                child: Text('删除',
                    style: TextStyle(color: colors.textMuted)),
              ),
            ],
          ),
          // B3-3：已连接 server 的 Skills over MCP 发现与导入（SEP-2640）。
          if (status == 'connected') ...[
            const SizedBox(height: 6),
            _McpSkillsSection(serverId: config.id, serverName: config.name),
          ],
          if (tools.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '工具（开关控制是否注入 Agent，执行按钮仅手动试调用）',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            for (final t in tools)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Switch(
                      value:
                          !config.disabledTools.contains(t.name),
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) => McpManager.instance
                          .setToolEnabled(config.id, t.name,
                              enabled: v),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        t.name,
                        style: TextStyle(
                          color: config.disabledTools
                                  .contains(t.name)
                              ? colors.textMuted
                              : colors.textPrimary,
                          fontSize: 12,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => onRunTool(t),
                      child: const Text('执行'),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// B3-3：MCP server 的 Skills 发现区（SEP-2640）——列出发间的 skills，
/// 一键把 SKILL.md 导入应用全局目录（保留 mcp-server/mcp-skill-uri 来源）。
/// skills/list 不可用时回退 resources/list 的 skill:// 发现。
class _McpSkillsSection extends StatefulWidget {
  const _McpSkillsSection({required this.serverId, required this.serverName});

  final String serverId;
  final String serverName;

  @override
  State<_McpSkillsSection> createState() => _McpSkillsSectionState();
}

class _McpSkillsSectionState extends State<_McpSkillsSection> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _skills = const [];
  final Set<String> _imported = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = McpManager.instance.sessionOf(widget.serverId);
    if (session == null || !session.connected) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _skills = const [];
      });
      return;
    }
    try {
      List<Map<String, dynamic>> found;
      try {
        found = await session.listSkills();
      } catch (_) {
        // skills/list 未实现：回退 resources 的 skill:// 发现。
        found = await session.discoverSkillsViaResources();
      }
      if (!mounted) return;
      setState(() {
        _skills = found;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  String _skillName(Map<String, dynamic> entry) {
    final front = entry['frontmatter'];
    if (front is Map && '${front['name'] ?? ''}'.trim().isNotEmpty) {
      return '${front['name']}'.trim();
    }
    final uri = '${entry['uri'] ?? ''}';
    final m = RegExp(r'skill(?:s)?://([^/]+)/').firstMatch(uri);
    return m != null ? m.group(1)! : uri;
  }

  String _skillDesc(Map<String, dynamic> entry) {
    final front = entry['frontmatter'];
    if (front is Map) return '${front['description'] ?? ''}'.trim();
    return '${entry['description'] ?? ''}'.trim();
  }

  Future<void> _import(Map<String, dynamic> entry) async {
    final session = McpManager.instance.sessionOf(widget.serverId);
    if (session == null) return;
    final uri = '${entry['uri'] ?? ''}';
    try {
      final text = await session.readResource(uri);
      await SkillManager.instance.importSkillFromMcpText(
        serverName: widget.serverName,
        skillUri: uri,
        skillMdText: text,
      );
      if (!mounted) return;
      setState(() => _imported.add(_skillName(entry)));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入 skill「${_skillName(entry)}」到全局目录')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('正在发现 Skills…', style: TextStyle(fontSize: 11.5)),
          ],
        ),
      );
    }
    if (_skills.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Skills（SEP-2640，导入后与本地 skill 同等可用，/skill-name 硬路由）',
          style: TextStyle(
            color: colors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        for (final entry in _skills)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _skillName(entry),
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 12,
                          fontFamily: 'Menlo',
                        ),
                      ),
                      if (_skillDesc(entry).isNotEmpty)
                        Text(
                          _skillDesc(entry),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: colors.textMuted, fontSize: 10.5),
                        ),
                      Text(
                        '${entry['uri'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: colors.textMuted, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _imported.contains(_skillName(entry))
                      ? null
                      : () => _import(entry),
                  child: Text(_imported.contains(_skillName(entry)) ? '已导入' : '导入'),
                ),
              ],
            ),
          ),
        if (_error != null)
          Text('Skills 发现失败：$_error',
              // E14：语义状态色随亮暗主题切换。
              style: TextStyle(color: colors.statusError, fontSize: 10.5)),
      ],
    );
  }
}
