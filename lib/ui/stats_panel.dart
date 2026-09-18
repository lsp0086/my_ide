import 'package:flutter/material.dart';

import '../ai/chat_store.dart';
import '../theme/app_colors.dart';
import '../version/checkpoint_store.dart';

/// 每日聚合统计：对话轮次 + token 消耗 + 文件改动。
class _DayStat {
  int userMessages = 0;
  int assistantTurns = 0;
  int promptTokens = 0;
  int completionTokens = 0;
  int durationMs = 0;
  int checkpointCount = 0;
  int fileChanges = 0;

  int get totalTokens => promptTokens + completionTokens;
  bool get isEmpty =>
      userMessages == 0 &&
      assistantTurns == 0 &&
      checkpointCount == 0 &&
      fileChanges == 0;

  /// 热力强度：对话轮次 + 文件改动。
  int get score => assistantTurns + fileChanges;
}

/// 边栏统计面板：GitHub 风格贡献热力图，点击每天弹出当日详情。
class StatsPanel extends StatelessWidget {
  const StatsPanel({super.key, this.onClose});

  final VoidCallback? onClose;

  /// GitHub 贡献绿：空 + 4 档由浅到深。
  static const _levels = <Color>[
    Color(0xFFEBEDF0),
    Color(0xFF9BE9A8),
    Color(0xFF40C463),
    Color(0xFF30A14E),
    Color(0xFF216E39),
  ];

  static DateTime _dayKey(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  Map<DateTime, _DayStat> _aggregate(
      List<ChatSession> sessions, List<CheckpointInfo> checkpoints) {
    final map = <DateTime, _DayStat>{};
    _DayStat statOf(DateTime dt) {
      final key = _dayKey(dt);
      return map.putIfAbsent(key, () => _DayStat());
    }

    for (final s in sessions) {
      for (final m in s.messages) {
        final st = statOf(m.createdAt ?? DateTime.now());
        if (m.role == 'user') {
          st.userMessages++;
        } else {
          st.assistantTurns++;
          st.promptTokens += m.promptTokens ?? 0;
          st.completionTokens += m.completionTokens ?? 0;
          st.durationMs += m.durationMs ?? 0;
        }
      }
    }
    for (final cp in checkpoints) {
      final st = statOf(cp.createdAt);
      st.checkpointCount++;
      st.fileChanges +=
          cp.files.where((e) => !e.endsWith('.DS_Store')).length;
    }
    return map;
  }

  int _levelFor(int score, int maxScore) {
    if (score <= 0 || maxScore <= 0) return 0;
    final ratio = score / maxScore;
    if (ratio > 0.75) return 4;
    if (ratio > 0.5) return 3;
    if (ratio > 0.25) return 2;
    return 1;
  }

  String _formatTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }

  String _formatDuration(int ms) {
    final seconds = (ms / 1000).round();
    if (seconds < 60) return '${seconds}s';
    return '${seconds ~/ 60}分${seconds % 60}s';
  }

  String _dateLabel(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  void _showDayDetail(
      BuildContext context, IdeColors colors, DateTime day, _DayStat st) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: colors.panelElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colors.borderStrong),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _dateLabel(day),
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: Icon(Icons.close_rounded,
                          size: 18, color: colors.textMuted),
                    ),
                  ],
                ),
                Divider(height: 16, color: colors.divider),
                _DetailRow(
                    label: '对话轮次',
                    value:
                        '${st.assistantTurns}（用户 ${st.userMessages} / 助手 ${st.assistantTurns}）'),
                const SizedBox(height: 8),
                _DetailRow(
                    label: '消耗 tokens',
                    value:
                        '共 ${_formatTokens(st.totalTokens)}（输入 ${_formatTokens(st.promptTokens)} / 输出 ${_formatTokens(st.completionTokens)}）'),
                const SizedBox(height: 8),
                _DetailRow(
                    label: '文件改动',
                    value:
                        '${st.fileChanges} 个（${st.checkpointCount} 个版本节点）'),
                const SizedBox(height: 8),
                _DetailRow(
                    label: '对话耗时',
                    value: _formatDuration(st.durationMs)),
                if (st.isEmpty) ...[
                  const SizedBox(height: 8),
                  Text('当天暂无对话与改动记录',
                      style: TextStyle(
                          color: colors.textMuted, fontSize: 12)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    final chats = ChatScope.of(context);
    final checkpoints = CheckpointScope.of(context);
    return AnimatedBuilder(
      animation:
          Listenable.merge(<Listenable>[chats, checkpoints]),
      builder: (context, _) {
        final stats = _aggregate(chats.sessions, checkpoints.checkpoints);
        var maxScore = 0;
        for (final st in stats.values) {
          if (st.score > maxScore) maxScore = st.score;
        }
        var totalTurns = 0;
        var totalTokens = 0;
        var activeDays = 0;
        for (final st in stats.values) {
          totalTurns += st.assistantTurns;
          totalTokens += st.totalTokens;
          if (!st.isEmpty) activeDays++;
        }

        // 最近 26 周（182 天），列为周、行为星期一~日。
        const weeks = 26;
        final today = _dayKey(DateTime.now());
        final weekday = today.weekday; // 1=周一
        final lastMonday =
            today.subtract(Duration(days: weekday - 1 + (weeks - 1) * 7));

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: colors.border),
                ),
              ),
              child: Row(
                children: [
                  Text(
                    '贡献统计',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const Spacer(),
                  if (onClose != null)
                    IconButton(
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      onPressed: onClose,
                      icon: Icon(Icons.close_rounded,
                          size: 16, color: colors.textMuted),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Wrap(
                spacing: 16,
                runSpacing: 4,
                children: [
                  _SummaryItem(
                      label: '对话轮次', value: '$totalTurns'),
                  _SummaryItem(
                      label: '消耗 tokens',
                      value: _formatTokens(totalTokens)),
                  _SummaryItem(
                      label: '活跃天数', value: '$activeDays'),
                ],
              ),
            ),
            Expanded(
              child: stats.isEmpty && checkpoints.checkpoints.isEmpty
                  ? Center(
                      child: Text(
                        '暂无统计数据，先开始一次 AI 对话',
                        style: TextStyle(
                            color: colors.textMuted, fontSize: 12.5),
                      ),
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 星期标签列
                          Column(
                            children: [
                              for (var r = 0; r < 7; r++)
                                Container(
                                  height: 13,
                                  margin: const EdgeInsets.only(bottom: 3),
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    r == 1
                                        ? '一'
                                        : r == 3
                                            ? '三'
                                            : r == 5
                                                ? '五'
                                                : '',
                                    style: TextStyle(
                                      color: colors.textMuted,
                                      fontSize: 9,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(width: 6),
                          for (var w = 0; w < weeks; w++)
                            Row(
                              children: [
                                Column(
                                  children: [
                                    for (var r = 0; r < 7; r++)
                                      Builder(
                                        builder: (_) {
                                          final day = lastMonday.add(
                                              Duration(
                                                  days: w * 7 + r));
                                          if (day.isAfter(today)) {
                                            return Container(
                                              width: 13,
                                              height: 13,
                                              margin:
                                                  const EdgeInsets.only(
                                                      bottom: 3),
                                            );
                                          }
                                          final st = stats[day];
                                          final level = _levelFor(
                                              st?.score ?? 0,
                                              maxScore);
                                          return Tooltip(
                                            message:
                                                '${_dateLabel(day)} · ${st?.assistantTurns ?? 0} 轮 · ${_formatTokens(st?.totalTokens ?? 0)} tokens',
                                            child: InkWell(
                                              onTap: () =>
                                                  _showDayDetail(
                                                      context,
                                                      colors,
                                                      day,
                                                      st ?? _DayStat()),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      3),
                                              child: Container(
                                                width: 13,
                                                height: 13,
                                                margin:
                                                    const EdgeInsets.only(
                                                        bottom: 3),
                                                decoration:
                                                    BoxDecoration(
                                                  color: _levels[level],
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          3),
                                                  border: Border.all(
                                                      color:
                                                          colors.border),
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                  ],
                                ),
                                const SizedBox(width: 3),
                              ],
                            ),
                        ],
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Row(
                children: [
                  Text('少',
                      style: TextStyle(
                          color: colors.textMuted, fontSize: 11)),
                  const SizedBox(width: 6),
                  for (var i = 0; i < _levels.length; i++)
                    Container(
                      width: 13,
                      height: 13,
                      margin: const EdgeInsets.only(right: 3),
                      decoration: BoxDecoration(
                        color: _levels[i],
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: colors.border),
                      ),
                    ),
                  const SizedBox(width: 6),
                  Text('多',
                      style: TextStyle(
                          color: colors.textMuted, fontSize: 11)),
                  const Spacer(),
                  Text('点击每天查看对话次数与 tokens',
                      style: TextStyle(
                          color: colors.textMuted, fontSize: 11)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontFamily: 'Menlo',
          ),
        ),
        Text(
          label,
          style:
              TextStyle(color: colors.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = IdeColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style:
                TextStyle(color: colors.textMuted, fontSize: 12.5),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 12.5,
              fontFamily: 'Menlo',
            ),
          ),
        ),
      ],
    );
  }
}
