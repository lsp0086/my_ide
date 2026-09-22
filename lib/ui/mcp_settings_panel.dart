import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mcp/mcp_client.dart';
import '../mcp/mcp_config.dart';
import '../mcp/mcp_manager.dart';
import '../theme/app_colors.dart';

/// 设置页 MCP 面板：增删改、导入/导出、连接与工具列表。
class McpSettingsPanel extends StatefulWidget {
  const McpSettingsPanel({super.key});

  @override
  State<McpSettingsPanel> createState() => _McpSettingsPanelState();
}

class _McpSettingsPanelState extends State<McpSettingsPanel> {
  final _manager = McpManager.instance;

  @override
  void initState() {
    super.initState();
    _manager.ensureLoaded();
    _manager.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _manager.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _importDialog() async {
    final controller = TextEditingController();
    final colors = IdeColors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text('导入 MCP 配置',
            style: TextStyle(color: colors.textPrimary)),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '支持 Claude Desktop / Cursor 的 mcpServers JSON，或本应用导出格式。',
                style: TextStyle(color: colors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                maxLines: 12,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12,
                  fontFamily: 'Menlo',
                ),
                decoration: InputDecoration(
                  hintText:
                      '{\n  "mcpServers": {\n    "filesystem": {\n      "command": "npx",\n      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]\n    }\n  }\n}',
                  hintStyle:
                      TextStyle(color: colors.textMuted, fontSize: 11),
                  filled: true,
                  fillColor: colors.panelHover,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final list = await _manager.importRaw(controller.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导入 ${list.length} 个 MCP 服务器（默认禁用，请在列表中启用）',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _export() async {
    final raw = _manager.exportRaw();
    await Clipboard.setData(ClipboardData(text: raw));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制 MCP 配置到剪贴板')),
    );
  }

  Future<void> _editServer({McpServerConfig? existing}) async {
    final created = existing == null;
    final draft = existing?.copy() ??
        McpServerConfig(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: 'mcp-server',
          command: 'npx',
          args: const ['-y', '@modelcontextprotocol/server-filesystem', '.'],
        );
    final name = TextEditingController(text: draft.name);
    final command = TextEditingController(text: draft.command);
    final args = TextEditingController(text: draft.args.join(' '));
    final cwd = TextEditingController(text: draft.cwd ?? '');
    final url = TextEditingController(text: draft.url);
    final headers = TextEditingController(
      text: draft.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
    );
    final timeout = TextEditingController(text: '${draft.timeoutSeconds}');
    final maxTools = TextEditingController(text: '${draft.maxTools}');
    final maxConcurrent =
        TextEditingController(text: '${draft.maxConcurrent}');
    final maxLogEntries =
        TextEditingController(text: '${draft.maxLogEntries}');
    final installDirectory =
        TextEditingController(text: draft.installDirectory ?? '');
    final version = TextEditingController(text: draft.version ?? '');
    final env = TextEditingController(
      text: draft.env.entries.map((e) => '${e.key}=${e.value}').join('\n'),
    );
    var transport = draft.transport;
    var enabled = draft.enabled;
    var toolLevel = draft.toolLevel;
    final colors = IdeColors.of(context);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: colors.panel,
              title: Text(created ? '添加 MCP' : '编辑 MCP',
                  style: TextStyle(color: colors.textPrimary)),
              content: SizedBox(
                width: 460,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(
                          labelText: '名称',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          ChoiceChip(
                            label: const Text('stdio'),
                            selected: transport == McpTransportType.stdio,
                            onSelected: (_) => setLocal(
                                () => transport = McpTransportType.stdio),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('HTTP'),
                            selected: transport == McpTransportType.http,
                            onSelected: (_) => setLocal(
                                () => transport = McpTransportType.http),
                          ),
                          const Spacer(),
                          Switch(
                            value: enabled,
                            onChanged: (v) => setLocal(() => enabled = v),
                          ),
                          const Text('启用'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (transport == McpTransportType.stdio) ...[
                        TextField(
                          controller: command,
                          decoration: const InputDecoration(
                            labelText: '命令',
                            hintText: 'npx / node / uvx',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: args,
                          decoration: const InputDecoration(
                            labelText: '参数（空格分隔）',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: cwd,
                          decoration: const InputDecoration(
                            labelText: '工作目录（可选）',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: env,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: '环境变量 KEY=VALUE（每行一个）',
                            isDense: true,
                          ),
                        ),
                      ] else ...[
                        TextField(
                          controller: url,
                          decoration: const InputDecoration(
                            labelText: 'URL',
                            hintText: 'http://127.0.0.1:3000/mcp',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: headers,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            labelText: '请求头 Key: Value（每行一个）',
                            isDense: true,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      TextField(
                        controller: timeout,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '超时秒数（5~300）',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          ChoiceChip(
                            label: const Text('只读'),
                            selected: toolLevel == McpToolLevel.read,
                            onSelected: (_) => setLocal(
                                () => toolLevel = McpToolLevel.read),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('可写'),
                            selected: toolLevel == McpToolLevel.write,
                            onSelected: (_) => setLocal(
                                () => toolLevel = McpToolLevel.write),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('网络'),
                            selected: toolLevel == McpToolLevel.network,
                            onSelected: (_) => setLocal(
                                () => toolLevel = McpToolLevel.network),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: maxTools,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '工具预算（1~200，超量按任务截断）',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: maxConcurrent,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '并发上限（1~32）',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: maxLogEntries,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '日志保留（20~1000）',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: version,
                        decoration: const InputDecoration(
                          labelText: '版本（可选）',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: installDirectory,
                        decoration: const InputDecoration(
                          labelText: '本地安装目录（可选，仅托管目录可卸载清理）',
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    if (saved != true) return;
    final nameText = name.text.trim();
    if (nameText.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称不能为空')),
      );
      return;
    }
    final envMap = <String, String>{};
    for (final line in env.text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf('=');
      if (i <= 0) continue;
      envMap[t.substring(0, i).trim()] = t.substring(i + 1).trim();
    }
    final headersMap = <String, String>{};
    for (final line in headers.text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf(':');
      if (i <= 0) continue;
      final k = t.substring(0, i).trim();
      final v = t.substring(i + 1).trim();
      if (k.isEmpty || v.isEmpty) continue;
      headersMap[k] = v;
    }
    final next = McpServerConfig(
      id: draft.id,
      name: nameText,
      enabled: enabled,
      transport: transport,
      command: command.text.trim(),
      args: args.text
          .trim()
          .split(RegExp(r'\s+'))
          .where((e) => e.isNotEmpty)
          .toList(),
      cwd: cwd.text.trim().isEmpty ? null : cwd.text.trim(),
      env: envMap,
      url: url.text.trim(),
      headers: headersMap,
      timeoutSeconds:
          (int.tryParse(timeout.text.trim()) ?? 45).clamp(5, 300),
      toolLevel: toolLevel,
      disabledTools: draft.disabledTools,
      maxTools: (int.tryParse(maxTools.text.trim()) ?? 40).clamp(1, 200),
      maxConcurrent:
          (int.tryParse(maxConcurrent.text.trim()) ?? 4).clamp(1, 32),
      maxLogEntries:
          (int.tryParse(maxLogEntries.text.trim()) ?? 200).clamp(20, 1000),
      installDirectory: installDirectory.text.trim().isEmpty
          ? null
          : installDirectory.text.trim(),
      version: version.text.trim().isEmpty ? null : version.text.trim(),
      dependencies: draft.dependencies,
    );
    await _manager.upsert(next);
    if (next.enabled) {
      await _manager.reconnect(next.id);
    } else {
      await _manager.disconnect(next.id);
    }
  }

  Future<void> _runTool(McpServerConfig server, McpToolDef tool) async {
    final colors = IdeColors.of(context);
    final argsCtrl = TextEditingController(text: '{}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text('执行 ${tool.name}',
            style: TextStyle(color: colors.textPrimary)),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: argsCtrl,
            maxLines: 8,
            style: TextStyle(
              color: colors.textPrimary,
              fontFamily: 'Menlo',
              fontSize: 12,
            ),
            decoration: const InputDecoration(
              labelText: 'arguments JSON',
              isDense: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('执行'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    Map<String, dynamic> args;
    try {
      final raw = argsCtrl.text.trim();
      final decoded = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('参数必须是 JSON 对象');
      }
      args = Map<String, dynamic>.from(decoded);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('参数 JSON 无效：$e')),
      );
      return;
    }
    final session = _manager.sessionOf(server.id);
    if (session == null || !session.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先连接 MCP 服务器')),
      );
      return;
    }
    final result = await session.callTool(tool.name, args);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text(result.ok ? '执行成功' : '执行失败',
            style: TextStyle(color: colors.textPrimary)),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              result.output,
              style: TextStyle(
                color: colors.textSecondary,
                fontFamily: 'Menlo',
                fontSize: 12,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: result.output));
              Navigator.pop(ctx);
            },
            child: const Text('复制并关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final servers = _manager.servers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '导入 Claude Desktop / Cursor 的 mcpServers，连接后工具会自动提供给 Agent。',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
            TextButton.icon(
              onPressed: _importDialog,
              icon: const Icon(Icons.file_upload_outlined, size: 16),
              label: const Text('导入'),
            ),
            TextButton.icon(
              onPressed: servers.isEmpty ? null : _export,
              icon: const Icon(Icons.copy_all_outlined, size: 16),
              label: const Text('导出'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => _editServer(),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('添加'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (servers.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.panelHover.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.border),
            ),
            child: Text(
              '尚未配置 MCP。可点击「导入」粘贴 JSON，或「添加」手动配置。',
              style: TextStyle(color: colors.textMuted, fontSize: 12.5),
            ),
          )
        else
          for (final s in servers)
            _McpServerTile(
              config: s,
              status: _manager.statusOf(s.id),
              tools: _manager.sessionOf(s.id)?.tools ?? const [],
              lastError: _manager.sessionOf(s.id)?.lastError ??
                  _manager.lastFailureOf(s.id),
              logs: _manager.sessionOf(s.id)?.logs ?? const [],
              onToggle: (v) => _manager.setEnabled(s.id, v),
              onConnect: () => _manager.reconnect(s.id),
              onDisconnect: () => _manager.disconnect(s.id),
              onEdit: () => _editServer(existing: s),
              onDelete: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: colors.panel,
                    title: Text('删除 ${s.name}？',
                        style: TextStyle(color: colors.textPrimary)),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (ok == true) await _manager.remove(s.id);
              },
              onRunTool: (tool) => _runTool(s, tool),
            ),
      ],
    );
  }
}

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
  });

  final McpServerConfig config;
  final String status;
  final List<McpToolDef> tools;
  final List<String> logs;
  final String? lastError;
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
      'connected' => const Color(0xFF3FB950),
      'connecting' => const Color(0xFFE5A000),
      'error' => const Color(0xFFE5484D),
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
              Switch(value: config.enabled, onChanged: onToggle),
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
          if (lastError != null && status == 'error') ...[
            const SizedBox(height: 4),
            Text(
              lastError!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFE5484D), fontSize: 11),
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
