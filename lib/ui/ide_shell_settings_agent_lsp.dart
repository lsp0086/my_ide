part of 'ide_shell.dart';

/// 语言服务器设置卡片域：_LanguageServerSettingsCard 及其状态
class _LanguageServerSettingsCard extends StatefulWidget {
  const _LanguageServerSettingsCard();

  @override
  State<_LanguageServerSettingsCard> createState() =>
      _LanguageServerSettingsCardState();
}

class _LanguageServerSettingsCardState
    extends State<_LanguageServerSettingsCard> {
  final Map<String, bool?> _status = {};
  final Map<String, TextEditingController> _controllers = {};
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    final settings = SettingsStore.instance;
    for (final spec in kLanguageServerSpecs) {
      _controllers[spec.id] = TextEditingController(
        text: settings.languageServerCommand(spec.id) ?? '',
      );
    }
    _refreshStatus();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    setState(() => _checking = true);
    DefinitionService.instance.invalidateAvailabilityCache();
    final settings = SettingsStore.instance;
    final next = <String, bool?>{};
    for (final spec in kLanguageServerSpecs) {
      final override =
          settings.languageServerCommand(spec.id) ??
          _controllers[spec.id]?.text;
      // 状态检测不强制下发；有应用目录二进制或 PATH 即视为可用。
      // 加超时，避免某一项卡住导致按钮一直「检测中」。
      try {
        next[spec.id] = await DefinitionService.instance
            .isAvailable(
              spec,
              commandOverride: (override != null && override.trim().isNotEmpty)
                  ? override
                  : null,
              ensureBundled: false,
            )
            .timeout(const Duration(seconds: 3), onTimeout: () => false);
      } catch (_) {
        next[spec.id] = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _status
        ..clear()
        ..addAll(next);
      _checking = false;
    });
  }

  Future<void> _save(String id) async {
    final text = _controllers[id]?.text.trim() ?? '';
    await SettingsStore.instance.setLanguageServerCommand(
      id,
      text.isEmpty ? null : text,
    );
    await _refreshStatus();
  }

  Future<void> _rebuildIndex() async {
    await SymbolIndex.instance.rebuild();
    if (mounted) setState(() {});
  }

  final Set<String> _installingIds = {};
  final Map<String, String> _installMsgs = {};

  Future<void> _downloadLanguagePack(LanguageServerSpec spec) async {
    final id = spec.id;
    if (_installingIds.contains(id)) return;
    setState(() {
      _installingIds.add(id);
      _installMsgs[id] = '正在下载到应用支持目录…';
    });
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('正在下载 ${spec.label}…')));
    }
    final consentId = id == 'html-via-ts' ? 'typescript' : id;
    await SettingsStore.instance.setLanguagePackConsent(consentId, true);
    final path = await BundledLanguageServers.instance.ensureInstalled(
      id,
      force: true,
    );
    DefinitionService.instance.invalidateAvailabilityCache();
    String extra = '';
    if (path != null && (id == 'typescript' || id == 'html-via-ts')) {
      final tss = await BundledLanguageServers.instance.tsserverJsPath();
      if (tss == null) {
        extra = '\n警告：缺少 tsserver.js（不要用 typescript@7）';
      } else {
        extra = '\ntsserver: $tss';
      }
    }
    if (!mounted) return;
    final msg = path != null
        ? '已下载：$path$extra'
        : (BundledLanguageServers.instance.lastErrorFor(id) ?? '下载失败');
    setState(() {
      _installingIds.remove(id);
      _installMsgs[id] = msg;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(path != null ? '${spec.label} 已就绪' : msg)),
    );
    await _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final index = SymbolIndex.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: colors.panelHover.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '内置符号索引',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '已内置 Dart / JS·TS / Python / Go / Rust / Java·Kotlin / C·C++ / C# / PHP / Ruby / Swift 定义+引用索引（参考 universal-ctags）。\n'
                '点定义看引用；点调用跳定义。\n'
                '${index.status ?? (index.rootPath == null ? '未打开项目' : '尚未索引')}',
                style: TextStyle(color: colors.textMuted, fontSize: 11.5),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: index.rootPath == null || index.indexing
                      ? null
                      : _rebuildIndex,
                  child: Text(index.indexing ? '索引中…' : '重建索引'),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: colors.panelHover.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '语言服务（按需下载）',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '安装包不预置语言服务。首次打开 JS/TS · Python · Go · Rust · C/C++ 文件时会询问是否下载到应用支持目录。\n'
                '也可在下方各条目右侧点「下载」手动获取（与检测弹窗相同）。不写系统全局，不改项目 jsconfig/tsconfig。\n'
                'JS 语义检查走 VS Code 同款 implicitProjectConfig（默认开启）。',
                style: TextStyle(color: colors.textMuted, fontSize: 11.5),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  '无配置 JS 启用 checkJs',
                  style: TextStyle(color: colors.textPrimary, fontSize: 13),
                ),
                subtitle: Text(
                  '不写 jsconfig；对散落 .js 文件检查未定义标识符等',
                  style: TextStyle(color: colors.textMuted, fontSize: 11),
                ),
                value: SettingsStore.instance.jsImplicitCheckJs,
                onChanged: (v) async {
                  await SettingsStore.instance.setJsImplicitCheckJs(v);
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                '语言服务器状态',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: _checking ? null : _refreshStatus,
              child: Text(_checking ? '检测中…' : '重新检测'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final spec in kLanguageServerSpecs) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.panelHover.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      (_status[spec.id] == true)
                          ? Icons.check_circle_rounded
                          : Icons.cancel_outlined,
                      size: 16,
                      // E14：语义状态色随亮暗主题切换。
                      color: (_status[spec.id] == true)
                          ? colors.statusOk
                          : colors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        spec.label,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      spec.extensions.join(' '),
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 11,
                        fontFamily: 'Menlo',
                      ),
                    ),
                    if (spec.autoInstall) ...[
                      const SizedBox(width: 8),
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: _installingIds.contains(spec.id)
                            ? null
                            : () => _downloadLanguagePack(spec),
                        icon: Icon(
                          _installingIds.contains(spec.id)
                              ? Icons.hourglass_top_rounded
                              : Icons.download_rounded,
                          size: 15,
                        ),
                        label: Text(
                          _installingIds.contains(spec.id)
                              ? '下载中…'
                              : (_status[spec.id] == true ? '重新下载' : '下载'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '默认命令：${spec.command} ${spec.args.join(' ')}\n${spec.installHint}',
                  style: TextStyle(color: colors.textMuted, fontSize: 11.5),
                ),
                if (_installMsgs[spec.id] != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _installMsgs[spec.id]!,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 11,
                      fontFamily: 'Menlo',
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controllers[spec.id],
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 12.5,
                          fontFamily: 'Menlo',
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText:
                              '可选：绝对路径覆盖，例如 /usr/local/bin/${spec.command}',
                          hintStyle: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11.5,
                          ),
                          filled: true,
                          fillColor: colors.panelElevated,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: colors.border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: colors.border),
                          ),
                        ),
                        onSubmitted: (_) => _save(spec.id),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () => _save(spec.id),
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        // R10：自定义语言服务器（PATH/绝对路径 command + 后缀映射）。
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: _addCustomServer,
            icon: const Icon(Icons.add_rounded, size: 15),
            label: const Text('新增自定义服务器', style: TextStyle(fontSize: 12)),
          ),
        ),
        const SizedBox(height: 8),
        for (final custom in _customServers()) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors.panelHover.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.extension_outlined, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${custom['label'] ?? custom['id']}  '
                    '${((custom['extensions'] as List?) ?? []).join(' ')}  →  '
                    '${custom['command']}',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 12,
                      fontFamily: 'Menlo',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: () => _removeCustomServer('${custom['id']}'),
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  List<Map<String, dynamic>> _customServers() =>
      SettingsStore.instance.customLanguageServers;

  Future<void> _removeCustomServer(String id) async {
    final list = _customServers().where((e) => '${e['id']}' != id).toList();
    await SettingsStore.instance.setCustomLanguageServers(list);
    DefinitionService.instance.invalidateAvailabilityCache();
    if (mounted) setState(() {});
  }

  Future<void> _addCustomServer() async {
    final idCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    final extCtl = TextEditingController();
    final cmdCtrl = TextEditingController();
    final argsCtl = TextEditingController();
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('新增自定义语言服务器'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: idCtrl,
                  decoration: const InputDecoration(
                    labelText: 'id（唯一，如 vue-ls）',
                  ),
                ),
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(labelText: '显示名（可选）'),
                ),
                TextField(
                  controller: extCtl,
                  decoration: const InputDecoration(
                    labelText: '后缀（空格分隔，如 .vue .svelte）',
                  ),
                ),
                TextField(
                  controller: cmdCtrl,
                  decoration: const InputDecoration(
                    labelText: '命令（PATH 名或绝对路径）',
                  ),
                ),
                TextField(
                  controller: argsCtl,
                  decoration: const InputDecoration(
                    labelText: '参数（空格分隔，如 --stdio，可空）',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('添加'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      final id = idCtrl.text.trim();
      final command = cmdCtrl.text.trim();
      if (id.isEmpty || command.isEmpty) {
        // 空 id/命令此前静默 return，用户毫无反馈；补 SnackBar 明示缺什么。
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              id.isEmpty ? 'id 不能为空' : '命令不能为空',
            ),
          ),
        );
        return;
      }
      if (kLanguageServerSpecs.any((s) => s.id == id)) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('id 与内置服务器冲突，换一个')));
        return;
      }
      final list = _customServers().where((e) => '${e['id']}' != id).toList();
      list.add({
        'id': id,
        'label': labelCtrl.text.trim().isEmpty ? id : labelCtrl.text.trim(),
        'extensions': extCtl.text
            .split(RegExp(r'[\s,;]+'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        'command': command,
        'args': argsCtl.text
            .split(RegExp(r'\s+'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
      });
      await SettingsStore.instance.setCustomLanguageServers(list);
      DefinitionService.instance.invalidateAvailabilityCache();
      if (mounted) setState(() {});
    } finally {
      idCtrl.dispose();
      labelCtrl.dispose();
      extCtl.dispose();
      cmdCtrl.dispose();
      argsCtl.dispose();
    }
  }
}

