import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../skills/skill_manager.dart';
import '../skills/skill_model.dart';
import '../theme/app_colors.dart';
import '../workspace/workspace_controller.dart';

/// 设置页 Skills 面板：多源发现、启用、导入 SKILL.md、全局目录。
class SkillsSettingsPanel extends StatefulWidget {
  const SkillsSettingsPanel({super.key});

  @override
  State<SkillsSettingsPanel> createState() => _SkillsSettingsPanelState();
}

class _SkillsSettingsPanelState extends State<SkillsSettingsPanel> {
  final _manager = SkillManager.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _manager.removeListener(_onChanged);
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    String? root;
    try {
      root = WorkspaceScope.of(context).rootPath;
    } catch (_) {
      root = null;
    }
    await _manager.ensureLoaded(
      workspaceRoot: root,
      forceRefresh: true,
    );
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _importMdText() async {
    final controller = TextEditingController();
    final colors = IdeColors.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text('导入 SKILL.md',
            style: TextStyle(color: colors.textPrimary)),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '粘贴符合 agentskills.io 的 SKILL.md（YAML frontmatter + Markdown）。'
                '将安装到本应用全局 skills 目录。',
                style: TextStyle(color: colors.textMuted, fontSize: 12.5),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                maxLines: 14,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12,
                  fontFamily: 'Menlo',
                ),
                decoration: InputDecoration(
                  hintText:
                      '---\nname: my-skill\ndescription: ...\n---\n# Instructions\n...',
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
            child: const Text('导入到全局'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final skill = await _manager.importSkillMdText(controller.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入全局 skill：${skill.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _importFolder() async {
    final path = await getDirectoryPath(confirmButtonText: '选择 Skill 文件夹');
    if (path == null || !mounted) return;
    try {
      final skill = await _manager.importSkillDirectory(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入全局 skill：${skill.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  Future<void> _addGlobalDir() async {
    final path = await getDirectoryPath(confirmButtonText: '添加全局 Skills 目录');
    if (path == null || !mounted) return;
    await _manager.addExtraGlobalDir(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加全局目录：$path')),
    );
  }

  Future<void> _showSkillDetail(AgentSkill skill) async {
    final colors = IdeColors.of(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text(skill.name,
            style: TextStyle(color: colors.textPrimary)),
        content: SizedBox(
          width: 520,
          height: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              [
                skill.description,
                '',
                '来源：${skill.sourceLabel}',
                '范围：${skill.scope == SkillScope.project ? '项目' : '全局'}',
                '路径：${skill.directoryPath}',
                if (skill.license != null) 'license: ${skill.license}',
                if (skill.parseWarning != null)
                  '警告：${skill.parseWarning}',
                '',
                '---',
                '',
                skill.body,
              ].join('\n'),
              style: TextStyle(
                color: colors.textSecondary,
                fontFamily: 'Menlo',
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: skill.body));
              Navigator.pop(ctx);
            },
            child: const Text('复制正文'),
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
    final skills = _manager.skills;
    final appDir = _manager.appGlobalSkillsDir;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '兼容 Agent Skills（SKILL.md）。扫描项目与用户目录，并可设置额外全局目录。',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _reload,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 18),
            ),
            TextButton.icon(
              onPressed: _importMdText,
              icon: const Icon(Icons.paste_outlined, size: 16),
              label: const Text('粘贴导入'),
            ),
            TextButton.icon(
              onPressed: _importFolder,
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              label: const Text('导入文件夹'),
            ),
          ],
        ),
        if (appDir != null) ...[
          const SizedBox(height: 6),
          SelectableText(
            '本应用全局目录：$appDir',
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 11.5,
              fontFamily: 'Menlo',
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          '扫描来源',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final e in SkillManager.knownSourceIds.entries)
              FilterChip(
                label: Text(e.value, style: const TextStyle(fontSize: 11.5)),
                selected: _manager.isSourceEnabled(e.key),
                onSelected: (v) => _manager.setSourceEnabled(e.key, v),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(
              '额外全局目录',
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _addGlobalDir,
              icon: const Icon(Icons.create_new_folder_outlined, size: 16),
              label: const Text('添加目录'),
            ),
          ],
        ),
        if (_manager.extraGlobalDirs.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '未添加。可将 Cursor/Claude 以外的自定义 skills 根目录挂到这里。',
              style: TextStyle(color: colors.textMuted, fontSize: 12),
            ),
          )
        else
          for (final dir in _manager.extraGlobalDirs)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: colors.panelHover.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      dir,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '移除',
                    onPressed: () => _manager.removeExtraGlobalDir(dir),
                    icon: Icon(Icons.close_rounded,
                        size: 16, color: colors.textMuted),
                  ),
                ],
              ),
            ),
        const SizedBox(height: 8),
        Text(
          '已发现 ${skills.length} 个 · 启用 ${_manager.enabledSkills.length} 个',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        if (skills.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.panelHover.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.border),
            ),
            child: Text(
              '尚未发现 Skill。可在项目下放 .agents/skills/<name>/SKILL.md，'
              '或导入到全局目录；也兼容 ~/.cursor/skills、~/.claude/skills。',
              style: TextStyle(color: colors.textMuted, fontSize: 12.5),
            ),
          )
        else
          for (final s in skills)
            _SkillTile(
              skill: s,
              enabled: _manager.isEnabled(s),
              onToggle: (v) => _manager.setEnabled(s, v),
              onOpen: () => _showSkillDetail(s),
              onDelete: s.sourceLabel == 'app:skills'
                  ? () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: colors.panel,
                          title: Text('删除全局 skill「${s.name}」？',
                              style: TextStyle(color: colors.textPrimary)),
                          content: Text(
                            '仅删除本应用全局目录中的副本，不会影响项目或其他工具目录。',
                            style: TextStyle(color: colors.textMuted),
                          ),
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
                      if (ok == true) {
                        await _manager.deleteAppGlobalSkill(s);
                      }
                    }
                  : null,
            ),
      ],
    );
  }
}

class _SkillTile extends StatelessWidget {
  const _SkillTile({
    required this.skill,
    required this.enabled,
    required this.onToggle,
    required this.onOpen,
    this.onDelete,
  });

  final AgentSkill skill;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final scopeLabel =
        skill.scope == SkillScope.project ? '项目' : '全局';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: colors.panelHover.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: InkWell(
              onTap: onOpen,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            skill.name,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _Pill(text: scopeLabel),
                        const SizedBox(width: 4),
                        _Pill(text: skill.sourceLabel),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      skill.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                    if (skill.parseWarning != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        skill.parseWarning!,
                        style: const TextStyle(
                          color: Color(0xFFE5A000),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Switch(
            value: enabled,
            onChanged: onToggle,
          ),
          if (onDelete != null)
            IconButton(
              tooltip: '删除',
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline_rounded,
                  size: 18, color: colors.textMuted),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colors.panelElevated,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        text,
        style: TextStyle(color: colors.textMuted, fontSize: 10.5),
      ),
    );
  }
}
