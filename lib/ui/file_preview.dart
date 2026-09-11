import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_colors.dart';
import '../workspace/workspace_controller.dart';
import 'code_editor.dart';

class FilePreviewPane extends StatelessWidget {
  const FilePreviewPane({
    super.key,
    required this.tab,
    this.editorKey,
  });

  final OpenEditorTab tab;
  final GlobalKey<CodeEditorPaneState>? editorKey;

  @override
  Widget build(BuildContext context) {
    switch (tab.kind) {
      case FileKind.text:
        return CodeEditorPane(
          key: editorKey,
          path: tab.path,
        );
      case FileKind.image:
        return _ImagePreview(path: tab.path);
      case FileKind.svg:
        return _SvgPreview(
          path: tab.path,
          editorKey: editorKey,
        );
      case FileKind.unsupported:
        return _SmartUnsupportedPreview(
          path: tab.path,
          name: tab.name,
          editorKey: editorKey,
        );
    }
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      color: colors.panelElevated,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: InteractiveViewer(
        minScale: 0.4,
        maxScale: 8,
        child: Image.file(
          File(path),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            return _Message(
              icon: Icons.broken_image_outlined,
              title: '图片加载失败',
              detail: '$error',
            );
          },
        ),
      ),
    );
  }
}

enum _SvgViewMode { preview, source }

class _SvgPreview extends StatefulWidget {
  const _SvgPreview({
    required this.path,
    this.editorKey,
  });

  final String path;
  final GlobalKey<CodeEditorPaneState>? editorKey;

  @override
  State<_SvgPreview> createState() => _SvgPreviewState();
}

class _SvgPreviewState extends State<_SvgPreview> {
  _SvgViewMode _mode = _SvgViewMode.preview;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: colors.panel,
            border: Border(
              bottom: BorderSide(color: colors.border),
            ),
          ),
          child: Row(
            children: [
              Text(
                'SVG',
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _SvgModeToggle(
                mode: _mode,
                onChanged: (mode) => setState(() => _mode = mode),
              ),
            ],
          ),
        ),
        Expanded(
          child: _mode == _SvgViewMode.preview
              ? _SvgCanvas(path: widget.path)
              : CodeEditorPane(
                  key: widget.editorKey,
                  path: widget.path,
                ),
        ),
      ],
    );
  }
}

class _SvgModeToggle extends StatelessWidget {
  const _SvgModeToggle({
    required this.mode,
    required this.onChanged,
  });

  final _SvgViewMode mode;
  final ValueChanged<_SvgViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: colors.panelHover,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SvgModeChip(
            label: '预览',
            selected: mode == _SvgViewMode.preview,
            onTap: () => onChanged(_SvgViewMode.preview),
          ),
          _SvgModeChip(
            label: '代码',
            selected: mode == _SvgViewMode.source,
            onTap: () => onChanged(_SvgViewMode.source),
          ),
        ],
      ),
    );
  }
}

class _SvgModeChip extends StatelessWidget {
  const _SvgModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? colors.panelElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? colors.borderStrong : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? colors.textPrimary : colors.textMuted,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _SvgCanvas extends StatelessWidget {
  const _SvgCanvas({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      color: colors.panelElevated,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: InteractiveViewer(
        minScale: 0.4,
        maxScale: 8,
        child: SvgPicture.file(
          File(path),
          fit: BoxFit.contain,
          placeholderBuilder: (context) {
            return const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          },
        ),
      ),
    );
  }
}

class _SmartUnsupportedPreview extends StatelessWidget {
  const _SmartUnsupportedPreview({
    required this.path,
    required this.name,
    this.editorKey,
  });

  final String path;
  final String name;
  final GlobalKey<CodeEditorPaneState>? editorKey;

  @override
  Widget build(BuildContext context) {
    if (WorkspaceController.looksLikeTextFile(path)) {
      return CodeEditorPane(
        key: editorKey,
        path: path,
      );
    }
    return _Message(
      icon: Icons.insert_drive_file_outlined,
      title: '暂不支持预览',
      detail: name,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: colors.textMuted),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textMuted, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

class EmptyEditorPane extends StatelessWidget {
  const EmptyEditorPane({
    super.key,
    this.hasWorkspace = false,
    this.onOpenFolder,
    this.recentProjects = const [],
    this.onOpenRecent,
    this.onRemoveRecent,
  });

  final bool hasWorkspace;
  final VoidCallback? onOpenFolder;
  final List<String> recentProjects;
  final ValueChanged<String>? onOpenRecent;
  final ValueChanged<String>? onRemoveRecent;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      color: colors.panelElevated,
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hasWorkspace
                        ? Icons.description_outlined
                        : Icons.folder_open_rounded,
                    size: 42,
                    color: colors.textMuted,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    hasWorkspace ? '未打开文件' : '未打开项目',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    hasWorkspace
                        ? '从左侧文件列表点击文件开始编辑'
                        : '先打开一个本地文件夹，再浏览其中的文件',
                    style:
                        TextStyle(color: colors.textMuted, fontSize: 12.5),
                  ),
                  if (!hasWorkspace && onOpenFolder != null) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: onOpenFolder,
                      icon:
                          const Icon(Icons.folder_open_rounded, size: 16),
                      label: const Text('打开项目'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!hasWorkspace && recentProjects.isNotEmpty)
            _RecentProjectsBar(
              projects: recentProjects,
              onOpen: onOpenRecent,
              onRemove: onRemoveRecent,
            ),
        ],
      ),
    );
  }
}

class _RecentProjectsBar extends StatelessWidget {
  const _RecentProjectsBar({
    required this.projects,
    this.onOpen,
    this.onRemove,
  });

  final List<String> projects;
  final ValueChanged<String>? onOpen;
  final ValueChanged<String>? onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Text(
              '最近项目',
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              itemCount: projects.length,
              itemBuilder: (context, index) {
                final path = projects[index];
                final name = path.split(RegExp(r'[/\\]')).last;
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: onOpen == null ? null : () => onOpen!(path),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.folder_rounded,
                              size: 16, color: colors.accent),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.textPrimary,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  path,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: colors.textMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (onRemove != null)
                            IconButton(
                              tooltip: '从历史移除',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                  width: 28, height: 28),
                              onPressed: () => onRemove!(path),
                              icon: Icon(Icons.close_rounded,
                                  size: 14, color: colors.textMuted),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
