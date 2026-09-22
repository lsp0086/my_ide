import 'package:flutter/material.dart';

/// 轨迹回放只读展示 widget（可编译即可，供命令面板/调试入口调用）。
class TrajectoryView extends StatelessWidget {
  const TrajectoryView({super.key, required this.markdown});

  final String markdown;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('轨迹回放'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(child: SelectableText(markdown)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

Future<void> showTrajectoryView(BuildContext context, String markdown) {
  return showDialog<void>(
    context: context,
    builder: (_) => TrajectoryView(markdown: markdown),
  );
}
