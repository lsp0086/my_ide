import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/diagnostics_store.dart';
import '../diagnostics/ide_diagnostic.dart';
import '../theme/app_colors.dart';
import '../workspace/workspace_controller.dart';

class ProblemsPanel extends StatelessWidget {
  const ProblemsPanel({
    super.key,
    required this.diagnostics,
    required this.workspace,
    this.onClose,
    this.onAiFix,
  });

  final DiagnosticsStore diagnostics;
  final WorkspaceController workspace;
  final VoidCallback? onClose;
  /// AI 修复入口：UI 侧注入，参数为要修复的诊断列表（空表示全部）。
  final void Function(List<IdeDiagnostic> diagnostics)? onAiFix;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return AnimatedBuilder(
      animation: diagnostics,
      builder: (context, _) {
        final items = diagnostics.allDiagnostics;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.border)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 16, color: colors.textSecondary),
                  const SizedBox(width: 8),
                  Text(
                    '问题',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${diagnostics.errorCount} 错误 · ${diagnostics.warningCount} 警告',
                    style: TextStyle(color: colors.textMuted, fontSize: 11),
                  ),
                  const Spacer(),
                  if (onAiFix != null && items.isNotEmpty)
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: Size.zero,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        tapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => onAiFix!(items),
                      child: const Text('AI 修复全部',
                          style: TextStyle(fontSize: 11)),
                    ),
                  if (onClose != null)
                    IconButton(
                      tooltip: '关闭',
                      onPressed: onClose,
                      icon: Icon(Icons.close, size: 16, color: colors.textMuted),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text(
                        '暂无问题',
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                    )
                  : ListView.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: colors.border),
                      itemBuilder: (context, index) {
                        final d = items[index];
                        return _ProblemTile(
                          diagnostic: d,
                          rootPath: workspace.rootPath,
                          onTap: () {
                            workspace.openFileAt(
                              d.filePath,
                              line: d.startLine,
                              character: d.startChar,
                            );
                          },
                          onAiFix: onAiFix == null
                              ? null
                              : () => onAiFix!([d]),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _ProblemTile extends StatelessWidget {
  const _ProblemTile({
    required this.diagnostic,
    required this.rootPath,
    required this.onTap,
    this.onAiFix,
  });

  final IdeDiagnostic diagnostic;
  final String? rootPath;
  final VoidCallback onTap;
  final VoidCallback? onAiFix;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final rel = rootPath != null && p.isWithin(rootPath!, diagnostic.filePath)
        ? p.relative(diagnostic.filePath, from: rootPath!)
        : p.basename(diagnostic.filePath);
    final color = _severityColor(diagnostic.severity, colors);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Icon(_severityIcon(diagnostic.severity), size: 14, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    diagnostic.message,
                    style: TextStyle(color: colors.textPrimary, fontSize: 12),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$rel:${diagnostic.displayLine}:${diagnostic.displayColumn} · ${diagnostic.source}',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontFamily: 'Menlo',
                    ),
                  ),
                ],
              ),
            ),
            if (onAiFix != null)
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: onAiFix,
                child: const Text('AI 修复',
                    style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }

  static IconData _severityIcon(DiagnosticSeverity s) {
    switch (s) {
      case DiagnosticSeverity.error:
        return Icons.error_rounded;
      case DiagnosticSeverity.warning:
        return Icons.warning_amber_rounded;
      case DiagnosticSeverity.info:
        return Icons.info_outline;
      case DiagnosticSeverity.hint:
        return Icons.lightbulb_outline;
    }
  }

  static Color _severityColor(DiagnosticSeverity s, IdeColors colors) {
    switch (s) {
      case DiagnosticSeverity.error:
        return const Color(0xFFE35D6A);
      case DiagnosticSeverity.warning:
        return const Color(0xFFE3A008);
      case DiagnosticSeverity.info:
        return colors.accent;
      case DiagnosticSeverity.hint:
        return colors.textMuted;
    }
  }
}
